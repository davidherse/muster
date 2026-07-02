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
        plan: fixture_file_upload("plan.pdf", "application/pdf"),
        questionnaire: { finish_level: "High-end", structural_work: [ "New pool" ] }
      } }
    end
    assert_equal "High-end", Estimate.order(:id).last.questionnaire["finish_level"]
    estimate = Estimate.order(:id).last
    assert_redirected_to estimate_url(estimate)
    assert estimate.processing?
    assert estimate.plan.attached?
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

  test "csv downloads for completed estimate" do
    @estimate.plan.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call

    get csv_estimate_url(@estimate)
    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match "TOTAL (ex. GST)", response.body
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

  test "destroy removes estimate" do
    assert_difference("Estimate.count", -1) do
      delete estimate_url(@estimate)
    end
    assert_redirected_to estimates_url
  end
end
