require "test_helper"

class PlanAnalyzerTest < ActiveSupport::TestCase
  setup do
    @estimate = users(:one).estimates.create!(name: "Reno", estimate_template: estimate_templates(:standard))
  end

  def attach(data, filename = "plan.pdf")
    @estimate.plan.attach(io: StringIO.new(data), filename: filename, content_type: "application/pdf")
  end

  def valid_pdf
    File.binread(Rails.root.join("test/fixtures/files/plan.pdf"))
  end

  test "sends parseable small PDF inline as base64" do
    attach(valid_pdf)
    client = FakeAiClient.new
    PlanAnalyzer.new(@estimate, client: client).call

    block = client.calls.first[:content].first
    assert_equal "base64", block.dig(:source, :type)
    assert_empty client.uploads
  end

  test "still sends PDF inline when pdf-reader cannot parse it" do
    attach("%PDF-1.7 not really parseable but small")
    client = FakeAiClient.new
    PlanAnalyzer.new(@estimate, client: client).call

    block = client.calls.first[:content].first
    assert_equal "base64", block.dig(:source, :type)
  end

  test "uploads oversized PDF via Files API and references it" do
    attach(valid_pdf)
    client = FakeAiClient.new
    PlanAnalyzer.new(@estimate, client: client, max_inline_bytes: 10).call

    block = client.calls.first[:content].first
    assert_equal "file", block.dig(:source, :type)
    assert_equal "file_fake_1", block.dig(:source, :file_id)
    assert_equal 1, client.uploads.size
  end
end
