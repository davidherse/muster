require "test_helper"

class QuestionsWizardTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    @estimate = users(:one).estimates.create!(name: "Reno", estimate_template: estimate_templates(:standard))
    @estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    @estimate.reload
    @estimate.update!(open_questions: [
      { "id" => 1, "question" => "Owner supplied appliances?", "why" => "Assumed builder", "sections" => [ "Structural Steel" ], "swing_low" => 0, "swing_high" => 8000 },
      { "id" => 2, "question" => "Prefab stairs?", "why" => "Assumed prefab", "sections" => [ "Preliminaries" ], "swing_low" => 0, "swing_high" => 4000 }
    ])
  end

  test "completed estimate with pending questions shows the wizard, not the estimate" do
    get estimate_url(@estimate)
    assert_response :success
    assert_match "A few questions before you see the number", response.body
    assert_match "of 2", response.body
    assert_no_match(/Where the money goes/, response.body)
  end

  test "answered questions bind, skipped ones never gate again" do
    assert_enqueued_with(job: GenerateEstimateJob) do
      post answer_questions_estimate_url(@estimate), params: { answers: { "1" => "Owner supplies", "2" => "" } }
    end
    @estimate.reload
    assert @estimate.processing?
    assert_equal [ "Owner supplies" ], @estimate.clarifications.map { |c| c["answer"] }
    assert_equal [ true ], @estimate.open_questions.map { |q| q["skipped"] }
    assert_not_includes @estimate.costed_sections, "Structural Steel"
    assert_includes @estimate.costed_sections, "Preliminaries", "skipped question's section untouched"
  end

  test "skipping everything shows the estimate without regenerating" do
    assert_no_enqueued_jobs(only: GenerateEstimateJob) do
      post answer_questions_estimate_url(@estimate), params: { answers: { "1" => "", "2" => " " } }
    end
    @estimate.reload
    assert @estimate.completed?
    assert_equal 2, @estimate.open_questions.count { |q| q["skipped"] }

    get estimate_url(@estimate)
    assert_match(/Where the money goes/, response.body)
    assert_no_match(/A few questions before you see the number/, response.body)
  end

  test "re-harvest preserves skipped questions and never re-gates them" do
    @estimate.update!(open_questions: [ @estimate.open_questions.first.merge("skipped" => true) ])
    QuestionHarvester.new(@estimate, client: FakeAiClient.new).call
    @estimate.reload
    skipped = @estimate.open_questions.select { |q| q["skipped"] }
    assert_equal 1, skipped.size, "skipped question survives re-harvest"
    fresh = @estimate.open_questions.reject { |q| q["skipped"] }
    assert fresh.any?
    assert_equal @estimate.open_questions.map { |q| q["id"] }.uniq.size, @estimate.open_questions.size, "ids stay unique"
  end
end
