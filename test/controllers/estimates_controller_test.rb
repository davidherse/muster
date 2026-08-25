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

  test "index lists my estimates" do
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

  test "create without plan re-renders with error" do
    assert_no_enqueued_jobs only: GenerateEstimateJob do
      post estimates_url, params: { estimate: { name: "No plan" } }
    end
    assert_response :unprocessable_entity
  end

  test "cannot see another user's estimate" do
    other = users(:two).estimates.create!(name: "Theirs")
    get estimate_url(other)
    assert_response :not_found
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

  test "new lists only my personal template and the default as layouts" do
    theirs = EstimateTemplate.create!(name: "Someone else's", user: users(:two), status: "active", sections: [ { "name" => "A" } ])
    proposal = EstimateTemplate.create!(name: "My unagreed proposal", user: @user, status: "proposed", sections: [ { "name" => "A" } ])
    mine = EstimateTemplate.create!(name: "My agreed one", user: @user, status: "active", sections: [ { "name" => "A" } ])
    get new_estimate_url
    assert_response :success
    assert_select "select[name='estimate[estimate_template_id]'] option", count: 2
    assert_select "option[value='#{mine.id}']"
    assert_select "option[value='#{estimate_templates(:standard).id}']"
    assert_select "option[value='#{theirs.id}']", count: 0
    assert_select "option[value='#{proposal.id}']", count: 0
  end
end
