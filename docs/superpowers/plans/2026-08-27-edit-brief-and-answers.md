# Edit Brief & Answers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user edit an estimate's brief, questionnaire and clarifying answers after generation and re-cost only the affected sections, never re-running the plan analysis.

**Architecture:** Reuse the generator's existing resume path (uncosted sections are re-costed against the stored `plan_summary`). The model gains `recost!`, `apply_questionnaire_overrides` (moved from the generator) and `reapply_questionnaire_overrides!`; clarifications keep their question's `sections`. `EstimatesController#edit/#update` drive a three-block form; a Stimulus `recost` controller pre-ticks the re-cost checklist as the user edits.

**Tech Stack:** Rails 8.1, Hotwire/Stimulus, Minitest + fixtures, `FakeAiClient`.

**Spec:** `docs/superpowers/specs/2026-08-27-edit-brief-and-answers-design.md`

## Global Constraints

- Ruby 3.4.4; prefix commands with `PATH=/home/davidherse/.local/share/mise/installs/ruby/3.4.4/bin:$PATH`; work in `~/Code/muster` on branch `edit-brief-and-answers`.
- `bin/rails test` = 184 runs, 0 failures at baseline; must stay at 0 failures. Rubocop clean on changed Ruby (2 pre-existing offences in `app/controllers/price_book_items_controller.rb` are out of scope).
- Estimates are account-scoped: `Current.account.estimates.find`. Fixtures: `users(:one)` owner of `accounts(:built)`, `users(:outsider)` in `accounts(:other)`, `estimate_templates(:standard)` (sections Preliminaries, Structural Steel, Solar Power System).
- Never re-run `PlanAnalyzer` from the edit flow. The questions gate is not re-opened.
- Exact copy: page title "Edit brief & answers"; notices "Saved. Nothing re-costed." and "Re-costing N sections…" (N = count, pluralised "section"/"sections"); alert when unavailable "This estimate can't be edited right now."

---

### Task 1: Model — section-tagged answers, overrides on the model, `recost!`

**Files:**
- Modify: `app/models/estimate.rb`, `app/services/estimate_generator.rb` (`apply_questionnaire_overrides` → delegate), `app/controllers/estimates_controller.rb` (`answer_questions` keeps `sections`)
- Test: `test/models/estimate_test.rb` (append), `test/controllers/questions_wizard_test.rb` (append one assertion)

**Interfaces:**
- Produces: `Estimate#apply_questionnaire_overrides(analysis) → analysis` (idempotent prefix), `Estimate#reapply_questionnaire_overrides! → true/false`, `Estimate#recost!(names) → Array<String>` (names scheduled), `Estimate#template_section_names → Array<String>`; clarifications carry `"sections"`.

- [ ] **Step 1: Write the failing tests**

Append inside `class EstimateTest`:

```ruby
  test "questionnaire overrides bind project type and area, idempotently" do
    e = users(:one).estimates.create!(name: "Q", estimate_template: estimate_templates(:standard),
      questionnaire: { "project_type" => EstimateQuestionnaire::PROJECT_TYPES.keys.first, "works_floor_area_m2" => "150" })
    klass = EstimateQuestionnaire::PROJECT_TYPES.values.first
    analysis = { "project_class" => "something_else", "floor_area_m2" => 90.0, "scope_summary" => "Two storey reno." }
    e.apply_questionnaire_overrides(analysis)
    e.apply_questionnaire_overrides(analysis)
    assert_equal klass, analysis["project_class"]
    assert_equal 150.0, analysis["floor_area_m2"]
    assert_equal 1, analysis["scope_summary"].scan("BUILDER-CONFIRMED PROJECT TYPE").size
    assert_match(/Two storey reno\.\z/, analysis["scope_summary"])
  end

  test "reapply_questionnaire_overrides! rewrites the stored analysis without an AI call" do
    e = users(:one).estimates.create!(name: "Q", estimate_template: estimate_templates(:standard),
      plan_summary: { "project_class" => "old", "floor_area_m2" => 90.0, "scope_summary" => "s" }, floor_area: "90.0")
    assert_not e.reapply_questionnaire_overrides! # nothing to override yet
    e.update!(questionnaire: { "works_floor_area_m2" => "210" })
    assert e.reapply_questionnaire_overrides!
    assert_equal 210.0, e.reload.plan_summary["floor_area_m2"]
    assert_equal "210.0", e.floor_area
    assert_not users(:one).estimates.create!(name: "No analysis", estimate_template: estimate_templates(:standard)).reapply_questionnaire_overrides!
  end

  test "recost! drops the named sections and their markers, ignoring unknown names" do
    e = users(:one).estimates.create!(name: "R", estimate_template: estimate_templates(:standard), status: "completed",
      costed_sections: [ "Preliminaries", "Structural Steel", "Solar Power System" ])
    e.sections.create!(name: "Preliminaries", position: 1)
    e.sections.create!(name: "Structural Steel", position: 2)
    scheduled = e.recost!([ "Structural Steel", "Not A Section" ])
    assert_equal [ "Structural Steel" ], scheduled
    e.reload
    assert_equal [ "Preliminaries", "Solar Power System" ], e.costed_sections
    assert_equal [ "Preliminaries" ], e.sections.pluck(:name)
    assert e.processing?
    assert_equal "Re-costing 1 section…", e.progress_note
    assert_equal [ "Preliminaries", "Structural Steel", "Solar Power System" ], e.template_section_names
  end
```

Append inside `QuestionsWizardTest` "answered questions bind, skipped ones never gate again", after the existing clarifications assertion:

```ruby
    assert_equal [ [ "Structural Steel" ] ], @estimate.clarifications.map { |c| c["sections"] }
```

(`EstimateSection` needs only `name`/`position` here — check `db/schema.rb` for other NOT NULL columns and supply them if any.)

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/estimate_test.rb test/controllers/questions_wizard_test.rb`
Expected: NoMethodError for the three new methods; the wizard assertion fails (`sections` nil).

- [ ] **Step 3: Implement**

`app/models/estimate.rb` — add:

```ruby
  OVERRIDE_PREFIX = /\ABUILDER-CONFIRMED PROJECT TYPE: [^.]*\. /

  # Builder-stated facts BIND over analyzer inference: the builder knows the
  # job type, and a stated works area pins the composite multiplier. Safe to
  # apply more than once — the recorded conflict note is replaced, not stacked.
  def apply_questionnaire_overrides(analysis)
    q = questionnaire.to_h
    if (klass = EstimateQuestionnaire::PROJECT_TYPES[q["project_type"]])
      base = analysis["scope_summary"].to_s.sub(OVERRIDE_PREFIX, "")
      original = analysis["original_project_class"] || analysis["project_class"]
      if original != klass
        analysis["original_project_class"] = original
        analysis["scope_summary"] = "BUILDER-CONFIRMED PROJECT TYPE: #{klass} (plans read as #{original}). " + base
        analysis["project_class"] = klass
      end
    end
    area = q["works_floor_area_m2"].to_f
    analysis["floor_area_m2"] = area if area.positive?
    analysis
  end

  # Re-apply the overrides to the stored analysis (after the questionnaire
  # changed) — no AI call. Returns false when there is no analysis or
  # nothing changed.
  def reapply_questionnaire_overrides!
    return false if plan_summary.blank?
    analysis = apply_questionnaire_overrides(plan_summary.deep_dup)
    return false if analysis == plan_summary
    update!(plan_summary: analysis, floor_area: analysis["floor_area_m2"].to_s)
    true
  end

  def template_section_names
    (estimate_template || EstimateTemplate.for_account(account))&.section_names || []
  end

  # Schedule sections for re-costing on the next resume run: drop their rows
  # and markers so the generator treats them as uncosted. Returns the names
  # actually scheduled (unknown names are ignored).
  def recost!(section_names)
    names = Array(section_names).map(&:to_s) & template_section_names
    return [] if names.empty?
    transaction do
      sections.where(name: names).destroy_all
      update!(costed_sections: costed_sections - names, status: "processing", error_message: nil,
        progress_note: "Re-costing #{names.size} #{'section'.pluralize(names.size)}…")
    end
    names
  end
```

`app/services/estimate_generator.rb` — replace the private `apply_questionnaire_overrides` body with a delegation (keep the call site in `fresh_analysis`):

```ruby
  def apply_questionnaire_overrides(analysis)
    @estimate.apply_questionnaire_overrides(analysis)
  end
```

`app/controllers/estimates_controller.rb#answer_questions` — `clarified = answered.map { |q| q.slice("question", "sections").merge("answer" => …) }`.

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/models/estimate_test.rb test/controllers/questions_wizard_test.rb && bin/rails test`
Expected: green (note the existing generator test "stores plan analysis" still passes — the override result is unchanged apart from the new `original_project_class` key).

- [ ] **Step 5: Rubocop and commit**

```bash
bin/rubocop app/models/estimate.rb app/services/estimate_generator.rb app/controllers/estimates_controller.rb test/models/estimate_test.rb test/controllers/questions_wizard_test.rb
git add app test
git commit -m "Estimate: section-tagged answers, questionnaire overrides on the model, recost!"
```

---

### Task 2: Controller — edit/update with computed or submitted re-cost set

**Files:**
- Modify: `app/controllers/estimates_controller.rb`
- Create: `app/views/estimates/edit.html.erb` (minimal — Task 3 replaces it; enough for `edit` to render: title + the three ids the tests look for are added in Task 3)
- Test: `test/controllers/estimates_controller_test.rb` (append)

**Interfaces:**
- Consumes: Task 1.
- Produces: `GET /estimates/:id/edit` (renders "Edit brief & answers"), `PATCH /estimates/:id` with params `estimate[name|prompt|questionnaire]`, `clarifications[<index>]`, `skipped_answers[<question id>]`, `recost_sections[]`, `recost_submitted`.

- [ ] **Step 1: Write the failing tests**

Append inside `class EstimatesControllerTest`. A helper first (inside the class):

```ruby
  def analysed_estimate(questionnaire: {})
    e = @user.estimates.create!(name: "Analysed", estimate_template: estimate_templates(:standard), status: "completed",
      questionnaire: questionnaire, prompt: "Original brief",
      plan_summary: { "project_class" => "whole_house_renovation", "floor_area_m2" => 120.0, "scope_summary" => "Reno." },
      costed_sections: [ "Preliminaries", "Structural Steel", "Solar Power System" ],
      clarifications: [ { "question" => "Prefab stairs?", "answer" => "Prefab", "sections" => [ "Structural Steel" ] } ],
      open_questions: [ { "id" => 7, "question" => "Owner appliances?", "sections" => [ "Preliminaries" ], "skipped" => true } ])
    e.sections.create!(name: "Preliminaries", position: 1)
    e.sections.create!(name: "Structural Steel", position: 2)
    e.sections.create!(name: "Solar Power System", position: 3)
    e
  end

  test "edit renders the brief, answers, skipped questions and the section checklist" do
    e = analysed_estimate(questionnaire: { "finish_level" => "High-end" })
    get edit_estimate_url(e)
    assert_response :success
    assert_match "Edit brief &amp; answers", response.body
    assert_select "input[name='estimate[name]'][value='Analysed']"
    assert_select "textarea[name='estimate[prompt]']", text: "Original brief"
    assert_select "textarea[name='clarifications[0]']", text: "Prefab"
    assert_match "Owner appliances?", response.body
    assert_select "textarea[name='skipped_answers[7]']"
    assert_select "input[type=checkbox][name='recost_sections[]'][value='Structural Steel']"
    assert_select "input[type=hidden][name=recost_submitted]"
  end

  test "edit is refused without an analysis or while generating" do
    bare = @user.estimates.create!(name: "Bare", estimate_template: estimate_templates(:standard))
    get edit_estimate_url(bare)
    assert_redirected_to estimate_url(bare)
    e = analysed_estimate
    e.update_columns(status: "processing", claimed_at: Time.current)
    get edit_estimate_url(e)
    assert_redirected_to estimate_url(e)
  end

  test "update of the name alone saves without re-costing" do
    e = analysed_estimate
    assert_no_enqueued_jobs(only: GenerateEstimateJob) do
      patch estimate_url(e), params: { estimate: { name: "Renamed", prompt: "Original brief" }, clarifications: { "0" => "Prefab" } }
    end
    assert_redirected_to estimate_url(e)
    assert_equal "Saved. Nothing re-costed.", flash[:notice]
    assert_equal "Renamed", e.reload.name
    assert_equal 3, e.sections.count
  end

  test "a changed answer re-costs only its sections" do
    e = analysed_estimate
    assert_enqueued_with(job: GenerateEstimateJob, args: [ e, { resume: true } ]) do
      patch estimate_url(e), params: { estimate: { name: "Analysed", prompt: "Original brief" }, clarifications: { "0" => "Site-built with newels" } }
    end
    e.reload
    assert_equal "Site-built with newels", e.clarifications.first["answer"]
    assert_equal [ "Structural Steel" ], e.clarifications.first["sections"]
    assert_equal [ "Preliminaries", "Solar Power System" ], e.costed_sections
    assert_equal [ "Preliminaries", "Solar Power System" ], e.sections.pluck(:name).sort
    assert e.processing?
    assert_equal "Re-costing 1 section…", e.progress_note
  end

  test "a changed questionnaire re-costs everything and re-applies overrides without re-analysing" do
    e = analysed_estimate
    klass_label = EstimateQuestionnaire::PROJECT_TYPES.keys.first
    assert_enqueued_with(job: GenerateEstimateJob, args: [ e, { resume: true } ]) do
      patch estimate_url(e), params: { estimate: { name: "Analysed", prompt: "Original brief", questionnaire: { project_type: klass_label, works_floor_area_m2: "200" } }, clarifications: { "0" => "Prefab" } }
    end
    e.reload
    assert_equal [], e.costed_sections
    assert_equal 0, e.sections.count
    assert_equal EstimateQuestionnaire::PROJECT_TYPES[klass_label], e.plan_summary["project_class"]
    assert_equal 200.0, e.plan_summary["floor_area_m2"]
    assert_equal "Re-costing 3 sections…", e.progress_note
  end

  test "answering a skipped question moves it into clarifications and re-costs its sections" do
    e = analysed_estimate
    patch estimate_url(e), params: { estimate: { name: "Analysed", prompt: "Original brief" }, clarifications: { "0" => "Prefab" }, skipped_answers: { "7" => "Owner supplies" } }
    e.reload
    assert_equal [ "Owner supplies" ], e.clarifications.map { |c| c["answer"] } - [ "Prefab" ]
    assert_equal [ "Preliminaries" ], e.clarifications.last["sections"]
    assert_empty e.open_questions
    assert_equal [ "Structural Steel", "Solar Power System" ], e.costed_sections
  end

  test "a submitted checklist wins, including an empty one" do
    e = analysed_estimate
    assert_no_enqueued_jobs(only: GenerateEstimateJob) do
      patch estimate_url(e), params: { estimate: { name: "Analysed", prompt: "Changed brief" }, clarifications: { "0" => "Prefab" }, recost_submitted: "1" }
    end
    assert_equal "Changed brief", e.reload.prompt
    assert_equal 3, e.sections.count
    assert_enqueued_with(job: GenerateEstimateJob) do
      patch estimate_url(e), params: { estimate: { name: "Analysed", prompt: "Changed brief" }, clarifications: { "0" => "Prefab" }, recost_submitted: "1", recost_sections: [ "Solar Power System" ] }
    end
    assert_equal [ "Preliminaries", "Structural Steel" ], e.reload.costed_sections
  end

  test "cannot edit another account's estimate" do
    other = users(:outsider).estimates.create!(name: "Theirs", plan_summary: { "a" => 1 })
    get edit_estimate_url(other)
    assert_response :not_found
    patch estimate_url(other), params: { estimate: { name: "X" } }
    assert_response :not_found
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/estimates_controller_test.rb`
Expected: `edit`/`update` actions missing → errors.

- [ ] **Step 3: Implement**

`app/controllers/estimates_controller.rb`:

- Add `:edit, :update` to the `set_estimate` before_action list and a new `before_action :require_editable!, only: %i[ edit update ]`.

```ruby
  def edit
    @sections = @estimate.template_section_names
    @answered = Array(@estimate.clarifications)
    @skipped = Array(@estimate.open_questions).select { |q| q["skipped"] }
  end

  # Save brief/questionnaire/answers and re-cost only what changed — never
  # re-analyse. The re-cost set is the submitted checklist when the form
  # sent one, else computed from what changed.
  def update
    @estimate.assign_attributes(brief_params)
    # The name never affects pricing; the brief text and questionnaire do.
    brief_changed = @estimate.will_save_change_to_prompt? || @estimate.will_save_change_to_questionnaire?

    affected = []
    answers = params.fetch(:clarifications, {}).permit!.to_h
    clarifications = Array(@estimate.clarifications).each_with_index.map do |c, i|
      next c unless answers.key?(i.to_s)
      answer = answers[i.to_s].to_s.strip
      next c if answer == c["answer"].to_s || answer.blank?
      affected.concat(c["sections"].presence || @estimate.template_section_names)
      c.merge("answer" => answer)
    end
    skipped_answers = params.fetch(:skipped_answers, {}).permit!.to_h
    open = Array(@estimate.open_questions).reject do |q|
      answer = skipped_answers[q["id"].to_s].to_s.strip
      next false if answer.blank?
      clarifications << q.slice("question", "sections").merge("answer" => answer)
      affected.concat(Array(q["sections"]).presence || @estimate.template_section_names)
      true
    end
    @estimate.assign_attributes(clarifications: clarifications, open_questions: open)

    unless @estimate.save
      @sections = @estimate.template_section_names; @answered = clarifications; @skipped = open.select { |q| q["skipped"] }
      return render :edit, status: :unprocessable_entity
    end

    computed = brief_changed ? @estimate.template_section_names : affected.uniq
    chosen = params[:recost_submitted].present? ? Array(params[:recost_sections]) : computed
    @estimate.reapply_questionnaire_overrides! if brief_changed
    scheduled = @estimate.recost!(chosen)
    if scheduled.empty?
      redirect_to @estimate, notice: "Saved. Nothing re-costed."
    else
      GenerateEstimateJob.perform_later(@estimate, resume: true)
      redirect_to @estimate, notice: "Re-costing #{scheduled.size} #{'section'.pluralize(scheduled.size)}…"
    end
  end
```

Private:

```ruby
  def require_editable!
    editable = @estimate.plan_summary.present? && !(@estimate.processing? && !@estimate.generation_stalled?)
    redirect_to @estimate, alert: "This estimate can't be edited right now." unless editable
  end

  def brief_params
    params.require(:estimate).permit(:name, :prompt, questionnaire: {})
  end
```

(`questionnaire` arrives as strings from the form; `will_save_change_to_questionnaire?` compares the assigned hash with the stored one, so a form that re-submits identical values does not count as a change. If a test shows blank-vs-missing keys registering as a change, normalise by dropping blank values from the submitted questionnaire before `assign_attributes`: `brief_params.merge(questionnaire: brief_params[:questionnaire].to_h.reject { |_, v| v.blank? })` when `questionnaire` is present.)

Minimal `app/views/estimates/edit.html.erb` for this task (Task 3 replaces it wholesale):

```erb
<h1 class="font-semibold text-3xl tracking-tight mb-2">Edit brief &amp; answers</h1>
<%= form_with model: @estimate, class: "contents" do |form| %>
  <%= form.text_field :name, class: ui_input %>
  <%= form.text_area :prompt, class: ui_textarea %>
  <%= render "shared/questionnaire_fields", answers: @estimate.questionnaire, param_root: "estimate" %>
  <% @answered.each_with_index do |c, i| %><p><%= c["question"] %></p><%= text_area_tag "clarifications[#{i}]", c["answer"], class: ui_textarea %><% end %>
  <% @skipped.each do |q| %><p><%= q["question"] %></p><%= text_area_tag "skipped_answers[#{q['id']}]", nil, class: ui_textarea %><% end %>
  <%= hidden_field_tag :recost_submitted, 1 %>
  <% @sections.each do |name| %><%= check_box_tag "recost_sections[]", name, false, id: nil %> <%= name %><% end %>
  <%= form.submit "Save" %>
<% end %>
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/controllers/estimates_controller_test.rb && bin/rails test`
Expected: green.

- [ ] **Step 5: Rubocop and commit**

```bash
bin/rubocop app/controllers/estimates_controller.rb test/controllers/estimates_controller_test.rb
git add app test
git commit -m "Estimates: edit brief and answers, re-costing only the affected sections"
```

---

### Task 3: The edit page, recost Stimulus controller, show-page link

**Files:**
- Replace: `app/views/estimates/edit.html.erb`
- Create: `app/javascript/controllers/recost_controller.js`
- Modify: `app/views/estimates/show.html.erb` (link beside "Regenerate estimate")
- Test: `test/controllers/estimates_controller_test.rb` (append)

- [ ] **Step 1: Write the failing tests**

```ruby
  test "show links to the editor once an analysis exists" do
    e = analysed_estimate
    get estimate_url(e)
    assert_select "a[href=?]", edit_estimate_path(e)
    bare = @user.estimates.create!(name: "Bare", estimate_template: estimate_templates(:standard))
    get estimate_url(bare)
    assert_select "a[href=?]", edit_estimate_path(bare), count: 0
  end

  test "edit page wires the recost controller" do
    e = analysed_estimate
    get edit_estimate_url(e)
    assert_select "[data-controller=recost]"
    assert_select "textarea[name='clarifications[0]'][data-recost-sections='Structural Steel']"
    assert_select "[data-recost-sections='*']"
    assert_select "input[type=checkbox][data-recost-target=section][data-section='Preliminaries']"
  end
```

- [ ] **Step 2: Run to verify failure** — `bin/rails test test/controllers/estimates_controller_test.rb` → the two new tests fail.

- [ ] **Step 3: Implement**

`app/views/estimates/edit.html.erb`:

```erb
<div class="mx-auto md:w-2/3 w-full" data-controller="recost">
  <h1 class="font-semibold text-3xl tracking-tight mb-2">Edit brief &amp; answers</h1>
  <p class="text-muted-foreground mb-6 text-sm">Change the details or your answers, then choose what to re-cost. The plan analysis is kept — only the ticked sections are priced again.</p>

  <%= form_with model: @estimate, class: "contents" do |form| %>
    <% if @estimate.errors.any? %>
      <div class="<%= ui_alert(variant: :destructive) %> mb-5"><ul class="list-disc list-inside"><% @estimate.errors.full_messages.each do |m| %><li><%= m %></li><% end %></ul></div>
    <% end %>

    <section class="<%= ui_card %> p-6 mb-6">
      <div class="grid gap-2">
        <%= form.label :name, "Project name", class: ui_label %>
        <%= form.text_field :name, required: true, class: ui_input %>
        <p class="text-xs text-muted-foreground">Renaming never re-costs anything.</p>
      </div>
    </section>

    <section class="<%= ui_card %> p-6 space-y-6 mb-6" data-recost-sections="*" data-action="input->recost#touch change->recost#touch">
      <h2 class="<%= ui_card_title %>">Original details</h2>
      <div class="grid gap-2">
        <%= form.label :prompt, "Brief", class: ui_label %>
        <%= form.text_area :prompt, rows: 6, class: ui_textarea %>
      </div>
      <%= render "shared/questionnaire_fields", answers: @estimate.questionnaire, param_root: "estimate" %>
    </section>

    <section class="<%= ui_card %> p-6 space-y-5 mb-6">
      <h2 class="<%= ui_card_title %>">Your answers</h2>
      <% if @answered.empty? && @skipped.empty? %>
        <p class="text-sm text-muted-foreground">No clarifying questions were asked for this estimate.</p>
      <% end %>
      <% @answered.each_with_index do |c, i| %>
        <div class="grid gap-2">
          <label class="<%= ui_label %>"><%= c["question"] %></label>
          <%= text_area_tag "clarifications[#{i}]", c["answer"], rows: 2, class: ui_textarea,
                data: { recost_sections: (c["sections"].presence || @sections).join("|"), action: "input->recost#touch" } %>
          <p class="text-xs text-muted-foreground">Affects: <%= (c["sections"].presence || [ "all sections" ]).join(", ") %></p>
        </div>
      <% end %>
      <% @skipped.each do |q| %>
        <div class="grid gap-2">
          <label class="<%= ui_label %>"><%= q["question"] %> <span class="<%= ui_badge(variant: :outline) %>">skipped</span></label>
          <%= text_area_tag "skipped_answers[#{q['id']}]", nil, rows: 2, placeholder: "Answer it now, or leave blank", class: ui_textarea,
                data: { recost_sections: (Array(q["sections"]).presence || @sections).join("|"), action: "input->recost#touch" } %>
        </div>
      <% end %>
    </section>

    <section class="<%= ui_card %> p-6 mb-6">
      <div class="flex items-baseline justify-between mb-3">
        <h2 class="<%= ui_card_title %>">What gets re-costed</h2>
        <div class="text-sm space-x-3">
          <a href="#" data-action="recost#all" class="underline underline-offset-4">Tick all</a>
          <a href="#" data-action="recost#none" class="underline underline-offset-4">Tick none</a>
        </div>
      </div>
      <p class="text-sm text-muted-foreground mb-4">Ticked automatically as you edit; untick anything you don't want touched. Nothing ticked = save only.</p>
      <%= hidden_field_tag :recost_submitted, 1 %>
      <div class="grid md:grid-cols-2 gap-2">
        <% @sections.each do |name| %>
          <label class="flex items-center gap-2 text-sm">
            <%= check_box_tag "recost_sections[]", name, false, id: nil, data: { recost_target: "section", section: name } %>
            <%= name %>
          </label>
        <% end %>
      </div>
    </section>

    <div class="flex items-center gap-3">
      <%= form.submit "Save and re-cost", class: ui_button %>
      <%= link_to "Cancel", estimate_path(@estimate), class: ui_button(variant: :ghost) %>
    </div>
  <% end %>
</div>
```

`app/javascript/controllers/recost_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Pre-ticks the re-cost checklist as the user edits: a field (or container)
// carrying data-recost-sections="A|B" ticks those sections; "*" ticks all.
export default class extends Controller {
  static targets = ["section"]

  touch(event) {
    const carrier = event.target.closest("[data-recost-sections]")
    if (!carrier) return
    const spec = carrier.dataset.recostSections
    const names = spec === "*" ? null : spec.split("|")
    this.sectionTargets.forEach((box) => {
      if (names === null || names.includes(box.dataset.section)) box.checked = true
    })
  }

  all(event) { event.preventDefault(); this.sectionTargets.forEach((b) => (b.checked = true)) }
  none(event) { event.preventDefault(); this.sectionTargets.forEach((b) => (b.checked = false)) }
}
```

`app/views/estimates/show.html.erb` — in the `flex justify-end mt-6` div beside "Regenerate estimate", add before it:

```erb
    <% if @estimate.plan_summary.present? %>
      <%= link_to "Edit brief & answers", edit_estimate_path(@estimate), class: ui_button(variant: :outline, size: :sm) %>
    <% end %>
```

and change that div's class to `flex justify-end gap-2 mt-6`.

- [ ] **Step 4: Run tests, rubocop, commit**

```bash
bin/rails test && bin/rubocop test/controllers/estimates_controller_test.rb
git add app/views/estimates app/javascript/controllers/recost_controller.js test/controllers/estimates_controller_test.rb
git commit -m "Edit brief & answers page with auto-ticked re-cost checklist"
```

---

### Task 4: Ship

- [ ] `bin/rails test && bin/rubocop` clean → `git push -u origin edit-brief-and-answers` → `gh pr create` (summary: edit page, section-tagged answers, resume-only re-costing, overrides re-applied without analysis) → `gh pr merge --merge` → on faber: `git pull`, `assets:precompile`, restart web + jobs, `/up` 200 (no migration).
- [ ] Browser smoke on faber: open a completed estimate → "Edit brief & answers" → change one answer → its sections auto-tick → Save → estimate page shows "Re-costing N sections…" and completes without a plan-analysis call (check `journalctl -u muster-jobs` shows no "Analysing plans").
