require "test_helper"

class EstimateQuestionnaireTest < ActiveSupport::TestCase
  test "renders answered questions in prompt order" do
    text = EstimateQuestionnaire.to_prompt(
      "repaint_extent" => "Full internal repaint",
      "finish_level" => "High-end",
      "structural_work" => [ "House raise / restumping", "New pool" ],
      "duration_months" => "13"
    )
    assert_includes text, "BUILDER'S CLARIFICATIONS"
    assert_includes text, "- Finish level: High-end"
    assert_includes text, "- Repaint extent: Full internal repaint"
    assert_includes text, "- Expected build duration (months): 13"
    assert_includes text, "- Structural work: House raise / restumping, New pool"
    # finish level listed before repaint (question order preserved)
    assert_operator text.index("Finish level"), :<, text.index("Repaint extent")
  end

  test "renders systems, external works, and PC items" do
    text = EstimateQuestionnaire.to_prompt(
      "systems_extras" => [ "Solar PV", "Plantation shutters" ],
      "external_works" => [ "Retaining walls", "Landscaping" ],
      "pc_items" => "Owner-supplied"
    )
    assert_includes text, "- Systems & extras to include: Solar PV, Plantation shutters"
    assert_includes text, "- External works in scope: Retaining walls, Landscaping"
    assert_includes text, "- Appliances & PC items: Owner-supplied"
  end

  test "omits blanks and returns nil when nothing answered" do
    assert_nil EstimateQuestionnaire.to_prompt({})
    assert_nil EstimateQuestionnaire.to_prompt(nil)
    assert_nil EstimateQuestionnaire.to_prompt("structural_work" => [ "" ], "inclusions" => "")
  end

  test "estimate brief_text combines prompt and questionnaire" do
    e = users(:one).estimates.create!(
      name: "Q", prompt: "Reno brief.",
      questionnaire: { "finish_level" => "Luxury" }
    )
    assert_includes e.brief_text, "Reno brief."
    assert_includes e.brief_text, "Finish level: Luxury"

    e.update!(questionnaire: {})
    assert_equal "Reno brief.", e.brief_text
  end

  test "questionnaire answers flow into the AI calls" do
    e = users(:one).estimates.create!(
      name: "Q2", questionnaire: { "repaint_extent" => "New work only" },
      estimate_template: estimate_templates(:standard)
    )
    e.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    client = FakeAiClient.new
    EstimateGenerator.new(e, client: client).call

    sent = client.calls.flat_map { |c| c[:content].map { |b| b[:text].to_s } }.join
    assert_includes sent, "Repaint extent: New work only"
  end
end
