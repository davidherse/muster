require "test_helper"

class EstimateGeneratorTest < ActiveSupport::TestCase
  setup do
    @estimate = users(:one).estimates.create!(name: "Reno", estimate_template: estimate_templates(:standard))
    @estimate.plan.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
  end

  test "generates sections, line items, totals, and range" do
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    @estimate.reload

    assert @estimate.completed?
    assert_equal "Renovation and extension", @estimate.building_type
    assert_equal %w[Preliminaries Structural\ Steel], @estimate.sections.map(&:name)
    assert_equal 4, @estimate.line_items.count

    # 2 sections x (2*100 + 10*70) = 1800
    assert_equal 1800.to_d, @estimate.total
    assert @estimate.total_low < @estimate.total
    assert @estimate.total_high > @estimate.total
    assert_equal 100, @estimate.progress
  end

  test "skips sections the model marks not applicable" do
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    assert_not @estimate.sections.exists?(name: "Solar Power System")
  end

  test "stores plan analysis on the estimate" do
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    assert_equal 210.0, @estimate.reload.plan_summary["floor_area_m2"]
    assert_equal "210.0", @estimate.floor_area
  end

  test "regenerating replaces previous sections" do
    generator = EstimateGenerator.new(@estimate, client: FakeAiClient.new)
    generator.call
    first_ids = @estimate.sections.pluck(:id)
    generator.call
    assert_empty first_ids & @estimate.reload.sections.pluck(:id)
    assert_equal 2, @estimate.sections.count
  end

  test "marks estimate failed with friendly message on AI error" do
    client = FakeAiClient.new(fail_with: Ai::Client::RefusalError.new("The model declined this request."))
    assert_raises(Ai::Client::RefusalError) do
      EstimateGenerator.new(@estimate, client: client).call
    end
    assert @estimate.reload.failed?
    assert_equal "The model declined this request.", @estimate.error_message
  end
end
