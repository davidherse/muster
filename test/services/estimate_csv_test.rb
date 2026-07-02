require "test_helper"

class EstimateCsvTest < ActiveSupport::TestCase
  test "includes metadata, sections, items, and totals" do
    estimate = users(:one).estimates.create!(name: "CSV Job", estimate_template: estimate_templates(:standard))
    estimate.plan.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    EstimateGenerator.new(estimate, client: FakeAiClient.new).call

    csv = CSV.parse(EstimateCsv.new(estimate.reload).generate)

    assert_equal [ "Estimate", "CSV Job" ], csv.first[0..1]
    header = csv.find { |row| row.first == "Section" }
    assert_includes header, "Range Low"
    assert csv.any? { |row| row[0].to_s.include?("Preliminaries") }
    assert csv.any? { |row| row[2].to_s.include?("Preliminaries materials") }
    total_row = csv.find { |row| row.first == "TOTAL (ex. GST)" }
    assert_equal "1800.00", total_row[7]
  end
end
