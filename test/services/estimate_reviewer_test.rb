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

class EstimateReviewerAdversarialTest < ActiveSupport::TestCase
  test "dual mode runs opposed completeness and padding passes" do
    estimate = users(:one).estimates.create!(name: "Adv", estimate_template: estimate_templates(:standard))
    estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    client = FakeAiClient.new
    ENV["ESTIMATOR_REVIEW_MODE"] = "dual"
    EstimateGenerator.new(estimate, client: client).call

    review_calls = client.calls.select { |c| c[:schema] == EstimateReviewer::SCHEMA }
    assert_equal 2, review_calls.size
    prompts = review_calls.map { |c| c[:system].map { |b| b[:text] }.join }
    assert prompts[0].include?("MISSING or UNDERDONE")
    assert prompts[1].include?("INVENTED or OVERDONE")
  ensure
    ENV.delete("ESTIMATOR_REVIEW_MODE")
  end

  # The padding pass is the one with a mandate to remove lines, so it is the
  # one that could strip a quote the builder actually holds.
  test "the padding pass is told never to touch a supplier-quoted line" do
    estimate = users(:one).estimates.create!(name: "Quoted", estimate_template: estimate_templates(:standard))
    estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    client = FakeAiClient.new
    ENV["ESTIMATOR_REVIEW_MODE"] = "dual"
    EstimateGenerator.new(estimate, client: client).call

    padding = client.calls.select { |c| c[:schema] == EstimateReviewer::SCHEMA }
                    .last[:system].map { |b| b[:text] }.join.squish
    assert_includes padding, "INVENTED or OVERDONE"
    assert_includes padding, "Quoted by"
    assert_includes padding, "never remove"
  ensure
    ENV.delete("ESTIMATOR_REVIEW_MODE")
  end

  test "auto mode picks the pass opposing the job's failure mode" do
    estimate = users(:one).estimates.create!(name: "Auto", estimate_template: estimate_templates(:standard))
    estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    client = FakeAiClient.new
    EstimateGenerator.new(estimate, client: client).call

    review_calls = client.calls.select { |c| c[:schema] == EstimateReviewer::SCHEMA }
    assert_equal 1, review_calls.size
    prompt = review_calls[0][:system].map { |b| b[:text] }.join
    # FakeAiClient's analysis is a whole-house class -> completeness pass
    assert prompt.include?("MISSING or UNDERDONE")
  end
end
