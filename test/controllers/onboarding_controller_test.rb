require "test_helper"

class OnboardingControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:two) }

  test "uploads step renders" do
    get onboarding_url
    assert_response :success
    assert_select "h1", /Show Muster how you estimate/
  end

  test "create_upload enqueues ingestion and stays in the wizard" do
    assert_enqueued_with(job: TrainingIngestJob) do
      post onboarding_uploads_url, params: { training_document: {
        name: "Old job", priced_on: Date.current.to_s,
        files: [ fixture_file_upload("plan.pdf", "application/pdf") ]
      } }
    end
    assert_redirected_to onboarding_url
  end

  test "template step shows progress while documents process" do
    doc = users(:two).training_documents.create!(name: "X", status: "processing")
    get onboarding_template_url
    assert_response :success
    assert_match "Reading your estimates", response.body

    get onboarding_status_url
    assert_equal "processing", response.parsed_body["status"]
  end

  test "template step shows the proposal and agree activates it" do
    doc = users(:two).training_documents.create!(name: "X")
    doc.files.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "e.pdf", content_type: "application/pdf")
    TrainingIngestor.new(doc, client: FakeAiClient.new).call
    TemplateSynthesizer.new(users(:two), client: FakeAiClient.new).call

    get onboarding_template_url
    assert_response :success
    assert_match "Wet Areas", response.body

    post onboarding_agree_url
    assert_redirected_to new_estimate_url
    assert users(:two).reload.onboarded_at.present?
    assert_equal "active", EstimateTemplate.find_by(user: users(:two)).status
    assert_equal [ "Prelims", "Carpentry", "Wet Areas", "Painting" ],
      EstimateTemplate.for_user(users(:two)).section_names
  end

  test "skip marks the user onboarded" do
    post onboarding_skip_url
    assert_redirected_to estimates_url
    assert users(:two).reload.onboarded_at.present?
  end

  test "sign-in routes new users into onboarding" do
    delete session_url
    post session_url, params: { email_address: users(:two).email_address, password: "password" }
    assert_redirected_to onboarding_url
  end

  test "sign-in skips onboarding for users with estimates" do
    users(:two).estimates.create!(name: "Job", prompt: "reno")
    delete session_url
    post session_url, params: { email_address: users(:two).email_address, password: "password" }
    assert_redirected_to estimates_url
  end
end
