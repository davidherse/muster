# Supplier Quotes + Round-2 Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Quote PDFs uploaded with the plans become binding "Quoted by …" lines for the trades they cover; plus four small calibration fixes from the Drayton v2 comparison.

**Architecture:** The plan analyser's structured output gains a `supplier_quotes` array (it already reads every uploaded PDF); the analysis JSON already flows verbatim into the generator prompt, so a new binding rule in `LineItemGenerator#instructions` costs quoted sections as one Sub line at the quoted amount. Calibration is prompt text, one `repaint_class` branch, one seeded base-book rate, and one console data step.

**Tech Stack:** Rails 8.1, Minitest + `FakeAiClient`.

**Spec:** `docs/superpowers/specs/2026-08-27-supplier-quotes-design.md`

## Global Constraints

- Ruby 3.4.4; `PATH=/home/davidherse/.local/share/mise/installs/ruby/3.4.4/bin:$PATH`; branch `supplier-quotes` from `main` (after the edit-brief PR merges). Suite must stay at 0 failures; rubocop clean on changed Ruby (2 pre-existing offences in `price_book_items_controller.rb` out of scope).
- Exact strings: rule headers `QUOTED TRADES ARE BINDING`, `SUPERVISION BY DURATION`, `SINGLE DUCTED SYSTEM`; line description prefix `Quoted by `; premium composite description `Whole-house repaint composite - full repaint, premium finish (high-end / luxury spec) - per m² floor` at unit_cost 300, uom `m2 floor`, category `Painting`, source_kind `base`; `repaint_class` value `"full repaint, premium finish"`.
- Never change what a specification or drawing counts as: only a priced document from a named supplier is a quote.

---

### Task 1: Analyser — `supplier_quotes` in the schema and prompts

**Files:** Modify `app/services/plan_analyzer.rb`, `test/support/fake_ai_client.rb`; Test `test/services/plan_analyzer_test.rb` (append).

**Interfaces:** Produces `analysis["supplier_quotes"]` = array of `{ "trade", "supplier", "amount_ex_gst", "gst_status", "includes", "excludes", "sections" }`; `FakeAiClient.new(analysis: FakeAiClient.quoted_analysis)` returns one quote.

- [ ] **Step 1: Failing tests** — append inside `class PlanAnalyzerTest`:

```ruby
  test "schema carries supplier quotes and the prompts ask for them" do
    props = PlanAnalyzer::SCHEMA[:properties]
    assert props.key?(:supplier_quotes)
    assert_equal %w[trade supplier amount_ex_gst gst_status includes excludes sections], props[:supplier_quotes][:items][:required]
    assert_includes PlanAnalyzer::SCHEMA[:required], "supplier_quotes"
    analyzer = PlanAnalyzer.new(@estimate, client: FakeAiClient.new)
    assert_match(/supplier quotes/i, analyzer.send(:user_prompt))
    assert_match(/supplier_quotes/, analyzer.send(:verification_prompt, {}))
  end

  test "fake client can hand back a quote" do
    q = FakeAiClient.quoted_analysis["supplier_quotes"].first
    assert_equal "West Tiling", q["supplier"]
    assert_equal [ "Structural Steel" ], q["sections"]
  end
```

(Use the test file's existing `@estimate` setup; if the class has none, create one as `estimate_generator_test.rb` does, with `plan.pdf` attached.)

- [ ] **Step 2: Run** — `bin/rails test test/services/plan_analyzer_test.rb` → fails on the missing key.

- [ ] **Step 3: Implement**

In `SCHEMA[:properties]` add (and add `"supplier_quotes"` to the top-level `required`):

```ruby
      supplier_quotes: {
        type: "array",
        description: "Supplier/subcontractor QUOTES found among the uploaded documents: a priced document from a NAMED supplier for a trade. Specifications, schedules and drawings are never quotes. Empty array if none.",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[trade supplier amount_ex_gst gst_status includes excludes sections],
          properties: {
            trade: { type: "string", description: "The trade quoted, e.g. Tiling, Cabinetry, Painting, Air-conditioning" },
            supplier: { type: "string", description: "Supplier/company name exactly as printed" },
            amount_ex_gst: { type: "number", description: "Quote total in AUD ex GST; if the document is inc GST divide by 1.1 and set gst_status to inc_gst" },
            gst_status: { type: "string", enum: %w[ex_gst inc_gst unclear] },
            includes: { type: "array", items: { type: "string" }, description: "What the quote covers (supply, labour, specific rooms/items)" },
            excludes: { type: "array", items: { type: "string" }, description: "What the quote explicitly excludes or leaves to the builder" },
            sections: { type: "array", items: { type: "string" }, description: "Exact COSTING SECTION names this quote covers" }
          }
        }
      },
```

`user_prompt`: change the first part to "Analyse the attached documents (architectural plans, specification schedules or reports, and any SUPPLIER QUOTES where provided) …" and append a part: "SUPPLIER QUOTES: if any uploaded document is a priced quote from a named supplier, record it in supplier_quotes with its ex-GST total (divide inc-GST totals by 1.1 and say so), what it includes and excludes, and the costing sections it covers. A drawing set or specification is never a quote."

`verification_prompt`: add a bullet "- supplier_quotes: every priced supplier document is listed once, with the correct ex-GST amount, inclusions/exclusions and covered sections; nothing that is a specification or drawing is listed".

`test/support/fake_ai_client.rb`: add `"supplier_quotes" => []` to `default_analysis`, and:

```ruby
  # A default analysis carrying one supplier quote covering Structural Steel
  # (a fixture section), for end-to-end quote tests.
  def self.quoted_analysis
    new.send(:default_analysis).merge("supplier_quotes" => [
      { "trade" => "Structural steel", "supplier" => "West Tiling", "amount_ex_gst" => 12_000.0, "gst_status" => "ex_gst",
        "includes" => [ "supply and install beams" ], "excludes" => [ "crane hire" ], "sections" => [ "Structural Steel" ] }
    ])
  end
```

- [ ] **Step 4: Run** — focused file, then full suite. Rubocop. Commit: `git commit -m "Plan analyser records supplier quotes found among the uploaded documents"`.

---

### Task 2: Generator — quoted trades are binding; calibration rules; premium repaint class

**Files:** Modify `app/services/line_item_generator.rb`, `db/seeds.rb`; Test `test/services/line_item_generator_test.rb` (append), `test/services/estimate_generator_test.rb` (append), `test/support/fake_ai_client.rb` (`sections_response` honours a quote).

**Interfaces:** Produces private `quotes_rule(sections)` (string or ""), rule constants; `repaint_class` may return `"full repaint, premium finish"`.

- [ ] **Step 1: Failing tests** — append inside `class LineItemGeneratorTest` (build generators as the file already does; `analysis` may be `FakeAiClient.quoted_analysis`):

```ruby
  test "quoted trades rule names the supplier, amount and section only when quotes exist" do
    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.quoted_analysis, client: client).call(steel_batch)
    system = client.calls.last[:system].map { |b| b[:text] || b["text"] }.join
    assert_match "QUOTED TRADES ARE BINDING", system
    assert_match "West Tiling", system
    assert_match "12000", system.delete(",")
    assert_match "Structural Steel", system

    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.new.send(:default_analysis), client: client).call(steel_batch)
    assert_no_match(/QUOTED TRADES ARE BINDING/, client.calls.last[:system].map { |b| b[:text] || b["text"] }.join)
  end

  test "premium repaint class for high-end finishes, standard otherwise, heritage untouched" do
    @estimate.update!(questionnaire: { "repaint_extent" => "Full repaint inside and out", "building_era" => "Post-1990" })
    assert_equal "full repaint, premium finish", generator_with(finish_level: "high_end").send(:repaint_class)
    assert_equal "full repaint, premium finish", generator_with(finish_level: "luxury").send(:repaint_class)
    assert_equal "full repaint of standard character home", generator_with(finish_level: "standard").send(:repaint_class)
    @estimate.update!(questionnaire: { "repaint_extent" => "Full repaint incl. VJ linings and fretwork", "building_era" => "Pre-1946 character home" })
    assert_equal "full heritage repaint", generator_with(finish_level: "high_end").send(:repaint_class)
  end

  test "supervision-by-duration and single-ducted-system rules are present" do
    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.new.send(:default_analysis), client: client).call(steel_batch)
    system = client.calls.last[:system].map { |b| b[:text] || b["text"] }.join
    assert_match "SUPERVISION BY DURATION", system
    assert_match "SINGLE DUCTED SYSTEM", system
  end
```

with helpers inside the class: `steel_batch` = `[ { "name" => "Structural Steel", "hint" => "Beams" } ]`; `generator_with(finish_level:)` = `LineItemGenerator.new(@estimate, analysis: FakeAiClient.new.send(:default_analysis).merge("finish_level" => finish_level), client: FakeAiClient.new)`.

Append inside `class EstimateGeneratorTest`:

```ruby
  test "a supplier quote becomes one Quoted-by line in its section" do
    client = FakeAiClient.new(analysis: FakeAiClient.quoted_analysis)
    EstimateGenerator.new(@estimate, client: client).call
    steel = @estimate.reload.sections.find_by!(name: "Structural Steel")
    quoted = steel.line_items.find { |i| i.description.start_with?("Quoted by ") }
    assert quoted, "expected a Quoted by line"
    assert_equal "Sub", quoted.item_type
    assert_equal 12_000.0, quoted.total.to_f
  end
```

`FakeAiClient#sections_response(content)`: when the request text contains "QUOTED TRADES ARE BINDING" and a section name in the batch matches a quote's `sections`, return for that section `[{ "description" => "Quoted by West Tiling — Structural steel", "item_type" => "Sub", "uom" => "Quoted", "quantity" => 1, "unit_cost" => 12000.0, "confidence" => "high", "assumptions" => "" }]` instead of the two generic lines (store the quotes on the instance from the analysis passed at construction: `@analysis&.dig("supplier_quotes")`).

- [ ] **Step 2: Run** — focused files → fail.

- [ ] **Step 3: Implement**

`LineItemGenerator`:
- `quotes_rule(sections)` (private): returns "" unless `Array(@analysis["supplier_quotes"]).any?`; else lists quotes whose `sections` intersect the batch's names (or all quotes when none intersect, so the model knows they exist), then the rule text:

```
QUOTED TRADES ARE BINDING: the builder holds these supplier quotes:
  - <supplier> — <trade>: $<amount> ex GST (<gst_status>); includes: …; excludes: …; covers: <sections>
Where a quote covers a section, cost that section as ONE Sub line described
"Quoted by <supplier> — <trade>" at the quoted ex-GST amount (quantity 1, uom
Quoted, confidence high), plus only the builder-side items the quote EXCLUDES
(supply the tiler doesn't, delivery, attendance). Never re-price a quoted
trade from rates, never add labour the quote already covers, and never mark a
quoted section inapplicable.
```

Interpolate it into `instructions` next to the PC rule. Amounts formatted with `number_with_delimiter`-free integers (`amount.to_i`).
- Static rules appended after SUPERVISION ONCE:
  - `SUPERVISION BY DURATION: when the builder states a duration and their book carries a monthly site-supervision allowance, cost Site Supervision as months × that monthly allowance (one line), not as hours.`
  - `SINGLE DUCTED SYSTEM: a stated single ducted air-conditioning system means ONE outdoor unit with its ducting and zoning — no additional ducted units or wall splits unless the brief or plans list them.`
- Crew rule text: after "plus a site labourer per week where the book carries one" insert "at the builder's own per-week labourer rate ('Site Labourer per week')".
- `repaint_class`: before the final `else`, add `elsif premium_finish?` → `"full repaint, premium finish"`, where `premium_finish?` = `%w[high_end luxury].include?(@analysis["finish_level"].to_s) || q["finish_level"].to_s =~ /high-end|luxury|premium/i`. Order: selective → raise → heritage → premium → standard.

`db/seeds.rb`: alongside the other base-book composites (find where `Whole-house repaint composite` rows are seeded; add one more row with the exact description/rate from Global Constraints; keep the seed idempotent the way its neighbours are).

- [ ] **Step 4: Run** — focused files, full suite, rubocop. Commit: `git commit -m "Quoted trades are binding; premium repaint class; supervision-by-duration and single-system rules"`.

---

### Task 3: UI — copy and the quote badge

**Files:** Modify `app/views/estimates/new.html.erb` (plans label + hint), `app/views/estimates/edit.html.erb` (if it lists plans — otherwise skip), `app/views/estimates/show.html.erb`; Test `test/controllers/estimates_controller_test.rb` (append).

- [ ] **Step 1: Failing test**

```ruby
  test "quoted lines carry a quote badge and the upload copy mentions quotes" do
    get new_estimate_url
    assert_match "supplier quotes", response.body
    e = @user.estimates.create!(name: "Q", estimate_template: estimate_templates(:standard), status: "completed", total: 1, total_low: 1, total_high: 1)
    s = e.sections.create!(name: "Tiling", position: 1)
    s.line_items.create!(description: "Quoted by West Tiling — Tiling", item_type: "Sub", uom: "Quoted", quantity: 1, unit_cost: 140_003, position: 1)
    get estimate_url(e)
    assert_select "span", text: "quote"
  end
```

(Supply any other NOT NULL columns `estimate_line_items` requires — check `db/schema.rb`; `total` may be computed by a callback.)

- [ ] **Step 2: Run** → fails. **Step 3:** label "Plans, specifications and any supplier quotes (PDF)" with hint "…plus any supplier quotes you hold — quoted trades are costed at the quote."; in `show.html.erb` after `<%= item.description %>` add `<% if item.description.start_with?("Quoted by ") %> <span class="<%= ui_badge(variant: :outline) %>">quote</span><% end %>`. **Step 4:** tests, commit `git commit -m "Quote badge on quoted lines; upload copy mentions supplier quotes"`.

---

### Task 4: Ship, seed, data, Drayton v3

- [ ] Full suite + rubocop → push → PR → merge → faber: `git pull`, `bin/rails db:seed` (premium composite), console: add the labourer book row (`PriceBookItem.create!(account: Account.first, source_kind: "user", category: "Carpentry & General Labour", description: "Site Labourer per week (1 man)", item_type: "Lab", uom: "week", unit_cost: 773, source: "manual:drayton-calibration", context: { "project_class" => "extension_and_renovation" })`), `assets:precompile`, restart both units, `/up` 200.
- [ ] Ask David for the quote PDFs he holds for Drayton (cabinetry, tiling, painting, air-con, plumbing fixtures if quoted); create "Drayton v3 (quotes)" from estimate 6's brief + PDFs + the quotes; generate; run `compare3.py` against v3.
