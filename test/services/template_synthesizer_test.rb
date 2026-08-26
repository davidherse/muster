require "test_helper"

class TemplateSynthesizerTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @doc = @user.training_documents.create!(name: "12 Smith St")
    @doc.files.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "estimate.pdf", content_type: "application/pdf")
    TrainingIngestor.new(@doc, client: FakeAiClient.new).call
  end

  test "synthesizes a proposed template for the account from completed uploads" do
    template = TemplateSynthesizer.new(@user.account, client: FakeAiClient.new).call

    assert template.persisted?
    assert_equal @user.account, template.account
    assert_equal "proposed", template.status
    assert_equal [ "Prelims", "Carpentry", "Wet Areas", "Painting" ], template.section_names
    assert_includes template.sections.first["typical_items"], "Supervision (Hour)"
  end

  test "re-synthesis replaces the existing proposal" do
    first = TemplateSynthesizer.new(@user.account, client: FakeAiClient.new).call
    second = TemplateSynthesizer.new(@user.account, client: FakeAiClient.new).call
    assert_equal first.id, second.id
    assert_equal 1, EstimateTemplate.where(account: @user.account, status: "proposed").count
  end

  test "returns nil with no completed uploads" do
    assert_nil TemplateSynthesizer.new(accounts(:other), client: FakeAiClient.new).call
  end

  test "activating a proposal supersedes the account's prior template and drives for_account" do
    proposal = TemplateSynthesizer.new(@user.account, client: FakeAiClient.new).call

    default = EstimateTemplate.for_account(@user.account)
    assert_not_equal proposal, default, "proposal must not apply before agreement"

    proposal.activate!
    assert_equal proposal, EstimateTemplate.for_account(@user.account)

    replacement = TemplateSynthesizer.new(@user.account, client: FakeAiClient.new).call
    replacement.activate!
    assert_equal replacement.reload, EstimateTemplate.for_account(@user.account)
    assert_not EstimateTemplate.exists?(proposal.id)
  end
end
