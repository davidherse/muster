require "test_helper"

class TrainingDocumentsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "create enqueues ingestion with questionnaire" do
    assert_enqueued_with(job: TrainingIngestJob) do
      post training_documents_url, params: { training_document: {
        name: "Old job",
        files: [ fixture_file_upload("plan.pdf", "application/pdf") ],
        questionnaire: { finish_level: "High-end" }
      } }
    end
    doc = TrainingDocument.order(:id).last
    assert_equal "High-end", doc.questionnaire["finish_level"]
    assert_redirected_to training_documents_url
  end

  test "destroy removes document and its rates" do
    doc = users(:one).training_documents.create!(name: "X")
    doc.files.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "e.pdf", content_type: "application/pdf")
    TrainingIngestor.new(doc, client: FakeAiClient.new).call
    assert_difference("PriceBookItem.for_account(accounts(:built)).count", -2) do
      delete training_document_url(doc)
    end
  end

  test "training documents are shared across the account, not across accounts" do
    users(:two).training_documents.create!(name: "Sam's upload")
    users(:outsider).training_documents.create!(name: "Outsider upload")
    get training_documents_url
    # assert_select, not assert_match: the rendered name is HTML-escaped.
    assert_select "p", text: "Sam's upload"
    assert_no_match(/Outsider upload/, response.body)
  end
end
