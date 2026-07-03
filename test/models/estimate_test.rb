require "test_helper"

class EstimateTest < ActiveSupport::TestCase
  setup do
    @estimate = users(:one).estimates.create!(name: "Reno", estimate_template: estimate_templates(:standard))
  end

  test "recalculate_totals! sums line items; range is assessed variance with 10% floor" do
    section = @estimate.sections.create!(name: "Framing", position: 1)
    section.line_items.create!(position: 1, description: "Timber", quantity: 2, unit_cost: 500, confidence: "high")
    section.line_items.create!(position: 2, description: "Labour", quantity: 10, unit_cost: 70, confidence: "low")

    @estimate.recalculate_totals!
    assert_equal 1700.to_d, @estimate.total
    assert_equal 1530.to_d, @estimate.total_low   # ±10% floor
    assert_equal 1870.to_d, @estimate.total_high

    @estimate.update!(assessment: { "expected_variance_pct" => 20.0 })
    @estimate.recalculate_totals!
    assert_equal 1360.to_d, @estimate.total_low   # widened by assessed variance
    assert_equal 2040.to_d, @estimate.total_high
  end

  test "fail! records message and status" do
    @estimate.fail!("boom")
    assert @estimate.failed?
    assert_equal "boom", @estimate.error_message
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
end
