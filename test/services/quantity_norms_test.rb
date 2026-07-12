require "test_helper"

class QuantityNormsTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @doc = @user.training_documents.create!(
      name: "12 Smith St",
      questionnaire: { "works_floor_area_m2" => "300", "duration_months" => "10",
                       "project_type" => "Whole-house renovation" }
    )
    @doc.files.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "e.pdf", content_type: "application/pdf")
    TrainingIngestor.new(@doc, client: FakeAiClient.new).call
  end

  test "derives per-m2 intensities from measured takeoff quantities" do
    norms = @user.reload.quantity_norms
    assert norms.present?, "ingest should derive norms"
    whole = norms.dig("groups", "whole")
    assert_equal 1, whole["docs"]
    # FakeAiClient: Internal repaint 120 m2 measured on a 300 m2 job
    assert_in_delta 0.4, whole.dig("buckets", "painting", "m2", "per_m2"), 0.001
    # lump entries (zero-cost note) never contribute
    assert_nil whole.dig("buckets", "preliminaries")
  end

  test "for_class picks the matching group and falls back" do
    norms = QuantityNorms.for_class(@user, "whole_house_renovation")
    assert norms.dig("buckets", "painting", "m2")
    # no 'small' group exists — small classes fall back to what's there
    assert_equal norms, QuantityNorms.for_class(@user, "small_works")
    assert_nil QuantityNorms.for_class(users(:two), "small_works")
  end

  test "docs without works area contribute nothing" do
    bare = users(:two).training_documents.create!(name: "No area")
    bare.files.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "e.pdf", content_type: "application/pdf")
    TrainingIngestor.new(bare, client: FakeAiClient.new).call
    assert_nil users(:two).reload.quantity_norms
  end
end
