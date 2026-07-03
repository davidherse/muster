require "test_helper"

class EstimateReviewerTest < ActiveSupport::TestCase
  setup do
    @estimate = users(:one).estimates.create!(name: "Reno", estimate_template: estimate_templates(:standard))
    @estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    @client = FakeAiClient.new
    EstimateGenerator.new(@estimate, client: @client).call
  end

  test "no changes leaves the estimate untouched" do
    assert_equal 1800.to_d, @estimate.reload.total
    assert_equal 4, @estimate.line_items.count
  end

  test "applies additions and removals, then totals reflect them" do
    @client.review_response = {
      "review_notes" => "Painting thin; labour double-counted.",
      "changes" => [
        {
          "section" => "Preliminaries", "reason" => "supervision missing",
          "remove_descriptions" => [ "Preliminaries labour" ],
          "add_items" => [
            { "description" => "Site supervision", "item_type" => "Lab", "uom" => "week",
              "quantity" => 10, "unit_cost" => 500.0, "confidence" => "medium", "assumptions" => "10 weeks" }
          ]
        }
      ]
    }
    EstimateReviewer.new(@estimate, analysis: @estimate.plan_summary, client: @client).call
    @estimate.recalculate_totals!

    section = @estimate.sections.find_by!(name: "Preliminaries")
    descriptions = section.line_items.pluck(:description)
    assert_includes descriptions, "Site supervision"
    refute_includes descriptions, "Preliminaries labour"
    # 1800 - 700 (removed labour) + 5000 (supervision) = 6100
    assert_equal 6100.to_d, @estimate.reload.total
  end

  test "removing every item drops the section" do
    @client.review_response = {
      "review_notes" => "Section not in scope.",
      "changes" => [
        { "section" => "Structural Steel", "reason" => "retained structure",
          "remove_descriptions" => [ "Structural Steel materials", "Structural Steel labour" ],
          "add_items" => [] }
      ]
    }
    EstimateReviewer.new(@estimate, analysis: @estimate.plan_summary, client: @client).call
    assert_not @estimate.sections.exists?(name: "Structural Steel")
  end
end
