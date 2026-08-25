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
end
