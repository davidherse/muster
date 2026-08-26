require "test_helper"

class EstimatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user
    @estimate = @user.estimates.create!(name: "Existing", estimate_template: estimate_templates(:standard))
  end

  test "requires authentication" do
    sign_out
    get estimates_url
    assert_redirected_to new_session_url
  end

  test "index lists the account's estimates" do
    get estimates_url
    assert_response :success
    assert_match "Existing", response.body
  end

  test "create attaches plan and enqueues generation" do
    assert_enqueued_with(job: GenerateEstimateJob) do
      post estimates_url, params: { estimate: {
        name: "New Job",
        prompt: "High-end finishes",
        estimate_template_id: estimate_templates(:standard).id,
        plans: [ fixture_file_upload("plan.pdf", "application/pdf") ],
        questionnaire: { finish_level: "High-end", structural_work: [ "New pool" ] }
      } }
    end
    assert_equal "High-end", Estimate.order(:id).last.questionnaire["finish_level"]
    estimate = Estimate.order(:id).last
    assert_redirected_to estimate_url(estimate)
    assert estimate.processing?
    assert estimate.plans.attached?
  end

  test "create ignores a template the account may not build on" do
    theirs = EstimateTemplate.create!(name: "Someone else's", account: accounts(:other), status: "active", sections: [ { "name" => "A" } ])
    post estimates_url, params: { estimate: {
      name: "Borrowed Layout",
      estimate_template_id: theirs.id,
      plans: [ fixture_file_upload("plan.pdf", "application/pdf") ]
    } }
    estimate = Estimate.find_by!(name: "Borrowed Layout")
    assert_equal estimate_templates(:standard), estimate.estimate_template,
      "another account's template must never be adopted, even when its id is posted"
  end

  test "create keeps the account's own template" do
    mine = EstimateTemplate.create!(name: "My agreed one", account: accounts(:built), status: "active", sections: [ { "name" => "A" } ])
    post estimates_url, params: { estimate: {
      name: "My Layout",
      estimate_template_id: mine.id,
      plans: [ fixture_file_upload("plan.pdf", "application/pdf") ]
    } }
    assert_equal mine, Estimate.find_by!(name: "My Layout").estimate_template
  end

  test "create without plan re-renders with error" do
    assert_no_enqueued_jobs only: GenerateEstimateJob do
      post estimates_url, params: { estimate: { name: "No plan" } }
    end
    assert_response :unprocessable_entity
  end

  test "the owner sees an estimate a member created" do
    theirs = users(:two).estimates.create!(name: "Sam's job")
    get estimate_url(theirs)
    assert_response :success
    get estimates_url
    # assert_select, not assert_match: the rendered name is HTML-escaped.
    assert_select "a", text: "Sam's job"
  end

  test "cannot see another account's estimate" do
    other = users(:outsider).estimates.create!(name: "Theirs")
    get estimate_url(other)
    assert_response :not_found
    get estimates_url
    assert_no_match(/Theirs/, response.body)
  end

  test "index shows who created each estimate" do
    users(:two).estimates.create!(name: "Sam's job")
    get estimates_url
    assert_match "Sam Renovator", response.body
  end

  test "status returns progress json" do
    @estimate.processing!("Analysing plans…")
    get status_estimate_url(@estimate)
    body = JSON.parse(response.body)
    assert_equal "processing", body["status"]
    assert_equal "Analysing plans…", body["note"]
  end

  test "csv downloads for completed estimate with no pending questions" do
    @estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    @estimate.reload.update!(open_questions: [])

    get csv_estimate_url(@estimate)
    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match "TOTAL (ex. GST)", response.body
  end

  test "csv is blocked while questions gate the estimate" do
    @estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    assert @estimate.reload.needs_answers?

    get csv_estimate_url(@estimate)
    assert_redirected_to estimate_url(@estimate)
  end

  test "csv redirects when not completed" do
    get csv_estimate_url(@estimate)
    assert_redirected_to estimate_url(@estimate)
  end

  test "regenerate enqueues job" do
    assert_enqueued_with(job: GenerateEstimateJob) do
      post regenerate_estimate_url(@estimate)
    end
    assert @estimate.reload.processing?
  end

  test "regenerate with resume resumes a failed estimate" do
    @estimate.update!(status: "failed", error_message: "boom", plan_summary: { "a" => 1 }, progress: 48)
    assert_enqueued_with(job: GenerateEstimateJob, args: [ @estimate, { resume: true } ]) do
      post regenerate_estimate_url(@estimate, resume: true)
    end
    assert @estimate.reload.processing?
    assert_equal 48, @estimate.progress
  end

  test "resume param ignored without prior analysis" do
    @estimate.update!(status: "failed", error_message: "boom", plan_summary: nil)
    assert_enqueued_with(job: GenerateEstimateJob, args: [ @estimate, { resume: false } ]) do
      post regenerate_estimate_url(@estimate, resume: true)
    end
  end

  test "regenerate refuses a live run" do
    @estimate.update!(status: "processing")
    @estimate.update_columns(claimed_at: Time.current)
    assert_no_enqueued_jobs only: GenerateEstimateJob do
      post regenerate_estimate_url(@estimate)
    end
    assert_redirected_to estimate_url(@estimate)
    assert_match "already being generated", flash[:alert]
  end

  test "regenerate resumes a stalled run" do
    # A worker died mid-run: Solid Queue never re-dispatches it, so the estimate
    # sits processing with a claim nothing is refreshing. Try again must work.
    @estimate.update!(status: "processing", plan_summary: { "a" => 1 }, progress: 48)
    @estimate.update_columns(claimed_at: 1.hour.ago)
    assert_enqueued_with(job: GenerateEstimateJob, args: [ @estimate, { resume: true } ]) do
      post regenerate_estimate_url(@estimate, resume: true)
    end
    assert @estimate.reload.processing?
    assert_equal 48, @estimate.progress
  end

  test "show offers Try again on a stalled run" do
    @estimate.update!(status: "processing")
    @estimate.update_columns(claimed_at: 1.hour.ago)
    get estimate_url(@estimate)
    assert_response :success
    assert_match "This run looks stalled", response.body
    assert_select "form[action=?]", regenerate_estimate_path(@estimate, resume: 1)
  end

  test "show does not offer Try again on a live run" do
    @estimate.update!(status: "processing")
    @estimate.update_columns(claimed_at: Time.current)
    get estimate_url(@estimate)
    assert_response :success
    assert_no_match(/This run looks stalled/, response.body)
  end

  test "destroy removes estimate" do
    assert_difference("Estimate.count", -1) do
      delete estimate_url(@estimate)
    end
    assert_redirected_to estimates_url
  end

  test "a created estimate actually generates when its job runs" do
    Ai::Client.stub(:new, ->(*_, **_) { FakeAiClient.new }) do
      perform_enqueued_jobs(only: GenerateEstimateJob) do
        post estimates_url, params: { estimate: {
          name: "Queued Job",
          estimate_template_id: estimate_templates(:standard).id,
          plans: [ fixture_file_upload("plan.pdf", "application/pdf") ]
        } }
      end
    end
    estimate = Estimate.find_by!(name: "Queued Job")
    assert estimate.completed?, "expected completed, got #{estimate.status}: #{estimate.error_message}"
    assert_equal 2, estimate.sections.count
    assert_nil estimate.claimed_at
  end

  test "new lists only my account's template and the default as layouts" do
    theirs = EstimateTemplate.create!(name: "Someone else's", account: accounts(:other), status: "active", sections: [ { "name" => "A" } ])
    proposal = EstimateTemplate.create!(name: "My unagreed proposal", account: accounts(:built), status: "proposed", sections: [ { "name" => "A" } ])
    mine = EstimateTemplate.create!(name: "My agreed one", account: accounts(:built), status: "active", sections: [ { "name" => "A" } ])
    get new_estimate_url
    assert_response :success
    assert_select "select[name='estimate[estimate_template_id]'] option", count: 2
    assert_select "option[value='#{mine.id}']"
    assert_select "option[value='#{estimate_templates(:standard).id}']"
    assert_select "option[value='#{theirs.id}']", count: 0
    assert_select "option[value='#{proposal.id}']", count: 0
  end

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
    assert_select "input[type=hidden][name=recost_submitted]" do |elements|
      assert_nil elements.first["value"], "the hidden field must render blank so the server's computed default can win"
    end
    assert_select "input[type=checkbox][data-section='Preliminaries'][data-action*='recost#manual']"
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

  test "a full-form round trip that only renames does not re-cost" do
    e = analysed_estimate
    all_blank = EstimateQuestionnaire::QUESTIONS.map { |q| [ q[:key], "" ] }.to_h
    assert_no_enqueued_jobs(only: GenerateEstimateJob) do
      patch estimate_url(e), params: { estimate: { name: "Renamed", prompt: "Original brief", questionnaire: all_blank }, clarifications: { "0" => "Prefab" } }
    end
    assert_equal "Saved. Nothing re-costed.", flash[:notice]
    e.reload
    assert_equal 3, e.sections.count
    assert_equal({}, e.questionnaire)
  end

  test "a full-form round trip that re-submits the same questionnaire value does not re-cost" do
    e = analysed_estimate(questionnaire: { "finish_level" => "High-end" })
    resubmitted = EstimateQuestionnaire::QUESTIONS.map { |q| [ q[:key], "" ] }.to_h.merge("finish_level" => "High-end")
    assert_no_enqueued_jobs(only: GenerateEstimateJob) do
      patch estimate_url(e), params: { estimate: { name: "Analysed", prompt: "Original brief", questionnaire: resubmitted }, clarifications: { "0" => "Prefab" } }
    end
    assert_equal "Saved. Nothing re-costed.", flash[:notice]
    e.reload
    assert_equal 3, e.sections.count
    assert_equal({ "finish_level" => "High-end" }, e.questionnaire)
  end

  test "a full-form round trip that actually changes a questionnaire value re-costs everything" do
    e = analysed_estimate(questionnaire: { "finish_level" => "High-end" })
    changed = EstimateQuestionnaire::QUESTIONS.map { |q| [ q[:key], "" ] }.to_h.merge("finish_level" => "Luxury")
    assert_enqueued_with(job: GenerateEstimateJob, args: [ e, { resume: true } ]) do
      patch estimate_url(e), params: { estimate: { name: "Analysed", prompt: "Original brief", questionnaire: changed }, clarifications: { "0" => "Prefab" } }
    end
    e.reload
    assert_equal 0, e.sections.count
    assert_equal [], e.costed_sections
    assert_equal({ "finish_level" => "Luxury" }, e.questionnaire)
    assert_equal "Re-costing 3 sections…", e.progress_note
  end
end
