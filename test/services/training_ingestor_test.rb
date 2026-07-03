require "test_helper"

class TrainingIngestorTest < ActiveSupport::TestCase
  setup do
    @doc = users(:one).training_documents.create!(
      name: "12 Smith St",
      questionnaire: { "finish_level" => "High-end", "site_conditions" => [ "Sloped block" ] }
    )
    @doc.files.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "estimate.pdf", content_type: "application/pdf")
  end

  test "ingests rates into the user price book with context and builds a template" do
    TrainingIngestor.new(@doc, client: FakeAiClient.new).call

    entries = PriceBookItem.for_user(users(:one))
    assert_equal 2, entries.count # zero-cost line skipped
    screen = entries.find_by!(description: "Semi-frameless shower screen")
    assert_equal "user", screen.source_kind
    assert_equal "High-end", screen.context["finish_level"]
    assert_equal "training:#{@doc.id}", screen.source

    template = EstimateTemplate.find_by!(name: "Dave Builder — 12 Smith St")
    assert_equal %w[Prelims Carpentry Wet\ Areas Painting], template.section_names
    assert @doc.reload.completed?
    assert_equal 3, @doc.extraction["item_count"]
  end

  test "re-ingesting replaces prior entries instead of duplicating" do
    TrainingIngestor.new(@doc, client: FakeAiClient.new).call
    TrainingIngestor.new(@doc, client: FakeAiClient.new).call
    assert_equal 2, PriceBookItem.for_user(users(:one)).count
  end

  test "user book appears in price book block and is preferred" do
    TrainingIngestor.new(@doc, client: FakeAiClient.new).call
    block = LineItemGenerator.price_book_block(users(:one))
    assert_includes block[:text], "USER PRICE BOOK"
    assert_includes block[:text], "Semi-frameless shower screen"
    assert_includes block[:text], "finish_level: High-end"
    assert_includes block[:text], "BASE PRICE BOOK"
    # user book absent for users without training
    assert_not_includes LineItemGenerator.price_book_block(users(:two))[:text], "USER PRICE BOOK"
  end

  test "failure marks document failed" do
    client = FakeAiClient.new(fail_with: Ai::Client::Error.new("bad doc"))
    assert_raises(Ai::Client::Error) { TrainingIngestor.new(@doc, client: client).call }
    assert @doc.reload.failed?
    assert_match "bad doc", @doc.error_message
  end
end

class TrainingIngestorEscalationTest < ActiveSupport::TestCase
  test "escalates rates from priced_on to current dollars" do
    doc = users(:one).training_documents.create!(name: "Old job", priced_on: Date.new(2021, 6, 1))
    doc.files.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "e.pdf", content_type: "application/pdf")
    TrainingIngestor.new(doc, client: FakeAiClient.new).call

    screen = PriceBookItem.where(user: users(:one)).find_by!("description LIKE ?", "%shower screen%")
    assert_equal (890 * 1.29).round(2).to_d, screen.unit_cost
    assert_match(/escalated x1.29 from 2021-06/, screen.source)
  end

  test "recent dates escalate to ~1.0" do
    assert_equal 1.0, PriceEscalation.factor(Date.current)
    assert_in_delta 1.29, PriceEscalation.factor(Date.new(2020, 1, 1)), 0.001 # clamped
    assert_in_delta 1.17, PriceEscalation.factor(Date.new(2022, 12, 15)), 0.01
  end
end
