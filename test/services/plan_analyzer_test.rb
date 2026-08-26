require "test_helper"

class PlanAnalyzerTest < ActiveSupport::TestCase
  setup do
    @estimate = users(:one).estimates.create!(name: "Reno", estimate_template: estimate_templates(:standard))
  end

  def attach(data, filename = "plan.pdf")
    @estimate.plans.attach(io: StringIO.new(data), filename: filename, content_type: "application/pdf")
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

  test "sends one document block per uploaded PDF" do
    attach(valid_pdf, "plans.pdf")
    attach(valid_pdf, "spec.pdf")
    client = FakeAiClient.new
    PlanAnalyzer.new(@estimate, client: client).call

    doc_blocks = client.calls.first[:content].select { |b| b[:type] == "document" }
    assert_equal 2, doc_blocks.size
    assert doc_blocks.all? { |b| b.dig(:source, :type) == "base64" }
  end

  test "second document overflows inline budget to Files API" do
    attach(valid_pdf, "plans.pdf")
    attach(valid_pdf, "spec.pdf")
    client = FakeAiClient.new
    PlanAnalyzer.new(@estimate, client: client, max_inline_bytes: valid_pdf.bytesize + 10).call

    doc_blocks = client.calls.first[:content].select { |b| b[:type] == "document" }
    assert_equal %w[base64 file], doc_blocks.map { |b| b.dig(:source, :type) }
    assert_equal 1, client.uploads.size
  end

  test "schema carries supplier quotes and the prompts ask for them" do
    props = PlanAnalyzer::SCHEMA[:properties]
    assert props.key?(:supplier_quotes)
    assert_equal %w[trade supplier amount_ex_gst gst_status includes excludes sections], props[:supplier_quotes][:items][:required]
    assert_includes PlanAnalyzer::SCHEMA[:required], "supplier_quotes"
    analyzer = PlanAnalyzer.new(@estimate, client: FakeAiClient.new)
    assert_match(/supplier quotes/i, analyzer.send(:user_prompt))
    assert_match(/supplier_quotes/, analyzer.send(:verification_prompt, {}))
  end

  test "fake client can hand back a quote" do
    q = FakeAiClient.quoted_analysis["supplier_quotes"].first
    assert_equal "West Tiling", q["supplier"]
    assert_equal [ "Structural Steel" ], q["sections"]
  end
end

class PlanAnalyzerVerificationTest < ActiveSupport::TestCase
  setup do
    @estimate = users(:one).estimates.create!(name: "V", estimate_template: estimate_templates(:standard))
    @estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
  end

  test "runs a verification pass that includes the draft" do
    client = FakeAiClient.new
    PlanAnalyzer.new(@estimate, client: client).call

    analysis_calls = client.calls.select { |c| c[:schema] == PlanAnalyzer::SCHEMA }
    assert_equal 2, analysis_calls.size
    second_text = analysis_calls.last[:content].map { |b| b[:text].to_s }.join
    assert_includes second_text, "DRAFT ANALYSIS"
    # documents carry a cache breakpoint so the re-read hits cache
    doc = analysis_calls.first[:content].find { |b| b[:type] == "document" }
    assert_equal({ type: "ephemeral" }, doc[:cache_control])
    # template section names offered for relevant_sections
    first_text = analysis_calls.first[:content].map { |b| b[:text].to_s }.join
    assert_includes first_text, "Structural Steel"
  end

  test "verify: false runs single pass" do
    client = FakeAiClient.new
    PlanAnalyzer.new(@estimate, client: client, verify: false).call
    assert_equal 1, client.calls.count { |c| c[:schema] == PlanAnalyzer::SCHEMA }
  end
end
