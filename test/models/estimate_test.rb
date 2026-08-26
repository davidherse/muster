require "test_helper"

class EstimateTest < ActiveSupport::TestCase
  setup do
    @estimate = users(:one).estimates.create!(name: "Reno", estimate_template: estimate_templates(:standard))
  end

  test "recalculate_totals! sums line items; range is a flat ±10%" do
    section = @estimate.sections.create!(name: "Framing", position: 1)
    section.line_items.create!(position: 1, description: "Timber", quantity: 2, unit_cost: 500, confidence: "high")
    section.line_items.create!(position: 2, description: "Labour", quantity: 10, unit_cost: 70, confidence: "low")

    @estimate.recalculate_totals!
    assert_equal 1700.to_d, @estimate.total
    assert_equal 1530.to_d, @estimate.total_low
    assert_equal 1870.to_d, @estimate.total_high
  end

  test "fail! records message and status" do
    @estimate.fail!("boom")
    assert @estimate.failed?
    assert_equal "boom", @estimate.error_message
  end

  test "claim_live? tracks the claim heartbeat, not the row's updated_at" do
    assert_not @estimate.claim_live?, "an unclaimed estimate is never live"

    @estimate.claimed_at = 1.minute.ago
    assert @estimate.claim_live?

    # Touched a moment ago (the controller marks it processing before
    # enqueuing) but the claim itself hasn't been refreshed in 16 minutes.
    @estimate.claimed_at = 16.minutes.ago
    @estimate.update_columns(updated_at: Time.current)
    assert_not @estimate.claim_live?
  end

  test "generation_stalled? spots a processing estimate nothing is working on" do
    @estimate.claimed_at = 1.hour.ago
    assert_not @estimate.generation_stalled?, "a draft estimate isn't generating at all"

    @estimate.status = "processing"
    @estimate.claimed_at = 1.minute.ago
    assert_not @estimate.generation_stalled?, "a heartbeating run is alive"

    @estimate.claimed_at = 16.minutes.ago
    assert @estimate.generation_stalled?

    # Queued but never claimed: updated_at stands in for the missing claim.
    @estimate.update!(claimed_at: nil)
    assert_not @estimate.generation_stalled?, "just queued"
    @estimate.update_columns(updated_at: 16.minutes.ago)
    assert @estimate.generation_stalled?
  end

  test "rejects non-PDF plan" do
    @estimate.plans.attach(io: StringIO.new("hello"), filename: "plan.txt", content_type: "text/plain")
    assert_not @estimate.valid?
    assert @estimate.errors[:plans].any?
  end

  test "accepts PDF plan" do
    @estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    assert @estimate.valid?
  end

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
end
