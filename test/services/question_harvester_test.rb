require "test_helper"

class QuestionHarvesterTest < ActiveSupport::TestCase
  setup do
    @estimate = users(:one).estimates.create!(name: "Reno", estimate_template: estimate_templates(:standard))
    @estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    @estimate.reload
  end

  test "generation harvests clarifying questions" do
    questions = @estimate.open_questions
    assert_equal 1, questions.size
    q = questions.first
    assert_equal 1, q["id"]
    assert_match(/appliances/, q["question"])
    assert_equal [ "Wet Areas" ], q["sections"]
  end

  test "answering a question binds it and re-costs only affected sections" do
    # give the estimate a section matching the question's target
    @estimate.update!(open_questions: [ { "id" => 1, "question" => "Owner supplied?",
      "why" => "", "sections" => [ "Structural Steel" ], "swing_low" => 0, "swing_high" => 5000 } ])

    section_names = @estimate.sections.map(&:name)
    assert_includes section_names, "Structural Steel"

    # simulate the controller flow
    question = @estimate.open_questions.first
    @estimate.update!(
      clarifications: [ { "question" => question["question"], "answer" => "Owner supplies the steel" } ],
      open_questions: []
    )
    affected = @estimate.sections.where(name: [ "Structural Steel" ])
    @estimate.update!(costed_sections: @estimate.costed_sections - affected.map(&:name))
    affected.destroy_all

    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call(resume: true)
    @estimate.reload

    assert @estimate.completed?
    assert_includes @estimate.sections.map(&:name), "Structural Steel"
    assert_equal 1, @estimate.sections.where(name: "Structural Steel").count, "no duplicate sections"
    assert_equal [ "Owner supplies the steel" ], @estimate.clarifications.map { |c| c["answer"] }
  end

  test "clarifications are injected into generation requests" do
    @estimate.update!(clarifications: [ { "question" => "Stairs prefab?", "answer" => "Prefab stringers, fix only" } ])
    client = FakeAiClient.new
    generator = LineItemGenerator.new(@estimate, analysis: FakeAiClient.new.send(:default_analysis), client: client)
    generator.call([ { "name" => "Preliminaries", "hint" => "" } ])
    request = client.calls.last[:content].first[:text]
    assert_match(/CLARIFIED SCOPE/, request)
    assert_match(/Prefab stringers/, request)
  end

  test "harvest failure does not fail the estimate" do
    estimate = users(:one).estimates.create!(name: "Reno 2", estimate_template: estimate_templates(:standard))
    estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    client = FakeAiClient.new
    def client.complete_json(system:, content:, schema:, max_tokens: nil)
      raise Ai::Client::Error, "harvest boom" if schema == QuestionHarvester::SCHEMA
      super
    end
    EstimateGenerator.new(estimate, client: client).call
    assert estimate.reload.completed?
    assert_empty Array(estimate.open_questions)
  end
end
