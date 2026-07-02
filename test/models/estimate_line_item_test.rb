require "test_helper"

class EstimateLineItemTest < ActiveSupport::TestCase
  setup do
    estimate = users(:one).estimates.create!(name: "Test", estimate_template: estimate_templates(:standard))
    @section = estimate.sections.create!(name: "Concrete Works", position: 1)
  end

  test "computes total from quantity and unit cost" do
    item = @section.line_items.create!(position: 1, description: "Slab", quantity: 10, unit_cost: 250)
    assert_equal 2500.to_d, item.total
  end

  test "range widens as confidence drops" do
    high = @section.line_items.create!(position: 1, description: "A", quantity: 1, unit_cost: 1000, confidence: "high")
    low  = @section.line_items.create!(position: 2, description: "B", quantity: 1, unit_cost: 1000, confidence: "low")
    assert_equal 900.0, high.range_low
    assert_equal 1100.0, high.range_high
    assert_equal 650.0, low.range_low
    assert_equal 1350.0, low.range_high
  end

  test "unknown confidence falls back to medium range" do
    item = @section.line_items.create!(position: 1, description: "C", quantity: 1, unit_cost: 100)
    assert_equal 80.0, item.range_low
    assert_equal 120.0, item.range_high
  end

  test "rejects invalid item type" do
    item = @section.line_items.new(position: 1, description: "X", item_type: "Bogus")
    assert_not item.valid?
  end
end
