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

  test "resume skips analysis and already-costed sections" do
    failing = FakeAiClient.new(fail_after: 2, fail_with: Ai::Client::Error.new("boom"))
    # batch_size 2 over 3 template sections => analysis + batch1 succeed, batch2 raises
    assert_raises(Ai::Client::Error) do
      EstimateGenerator.new(@estimate, client: failing, batch_size: 2).call
    end
    @estimate.reload
    assert @estimate.failed?
    assert_equal %w[Preliminaries Structural\ Steel], @estimate.costed_sections
    sections_before = @estimate.sections.pluck(:id)

    good = FakeAiClient.new
    EstimateGenerator.new(@estimate, client: good, batch_size: 2).call(resume: true)
    @estimate.reload

    assert @estimate.completed?
    # resume must not re-run plan analysis
    assert good.calls.none? { |c| c[:schema] == PlanAnalyzer::SCHEMA }
    # only the remaining section was requested from the line item generator
    line_item_calls = good.calls.select { |c| c[:schema] == LineItemGenerator::SCHEMA }
    requested = line_item_calls.flat_map { |c| c[:content].map { |b| b[:text] } }.join
    assert_includes requested, "Solar Power System"
    refute_includes requested, "Preliminaries"
    # previously costed sections retained, not duplicated
    assert_equal sections_before.sort, (@estimate.sections.pluck(:id) & sections_before).sort
    assert_equal 2, @estimate.sections.count
    assert_equal 3, @estimate.costed_sections.size
  end

  test "fresh run resets costed sections" do
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    assert_equal 3, @estimate.reload.costed_sections.size
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    assert_equal 3, @estimate.reload.costed_sections.size
    assert_equal 2, @estimate.sections.count
  end
end
