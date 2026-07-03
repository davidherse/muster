# Ingests a builder's own past estimate (PDF or spreadsheet) into their user
# price book and a personal estimate template. The questionnaire answered at
# upload time is attached as context to every extracted rate, so the
# estimator later knows what this builder's "high-end, sloped block" pricing
# actually looks like.
class TrainingIngestor
  SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[project_summary template_sections items],
    properties: {
      project_summary: { type: "string", description: "One paragraph: what this estimate covers" },
      template_sections: {
        type: "array", items: { type: "string" },
        description: "The estimate's own section/work-group names, in document order"
      },
      items: {
        type: "array",
        description: "Every priced line item with a usable unit rate. Skip notes, blanks and $0 lines.",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[category description item_type uom unit_cost],
          properties: {
            category: { type: "string", description: "The section/work group it belongs to" },
            description: { type: "string" },
            item_type: { type: "string", enum: EstimateLineItem::ITEM_TYPES },
            uom: { type: "string" },
            unit_cost: { type: "number", description: "AUD ex. GST per unit as documented" }
          }
        }
      }
    }
  }.freeze

  def initialize(training_document, client: Ai::Client.new)
    @doc = training_document
    @client = client
  end

  def call
    @doc.update!(status: "processing", error_message: nil)
    result = @client.complete_json(
      system: [ { type: "text", text: instructions } ],
      content: content_blocks,
      schema: SCHEMA
    )

    replace_price_book_entries(result)
    upsert_template(result)
    @doc.update!(status: "completed", extraction: result.slice("project_summary", "template_sections")
      .merge("item_count" => result["items"].size))
  rescue StandardError => e
    @doc.update!(status: "failed", error_message: e.message.to_s.truncate(1000))
    raise
  end

  private

  def instructions
    <<~PROMPT
      You are digitising a residential builder's own estimate document so their
      rates can ground future AI estimates. Extract every priced line item with
      its unit rate exactly as documented — do not adjust, index, or improve the
      numbers. Where a line only has a total with quantity 1, the total is the
      unit rate (uom Allowance or ea). Keep the builder's own section names.
    PROMPT
  end

  def content_blocks
    blocks = @doc.files.map { |file| block_for(file) }
    blocks + [ { type: "text", text: "Extract the estimate's sections and priced line items." } ]
  end

  def block_for(file)
    if file.content_type == "application/pdf"
      { type: "document", source: { type: "base64", media_type: "application/pdf",
                                    data: Base64.strict_encode64(file.download) } }
    else
      { type: "text", text: "ESTIMATE SPREADSHEET (#{file.filename}) AS CSV:\n#{spreadsheet_to_csv(file)}" }
    end
  end

  def spreadsheet_to_csv(file)
    file.open do |f|
      sheet = Roo::Spreadsheet.open(f.path, extension: File.extname(file.filename.to_s).delete("."))
      csv = sheet.sheet(0).to_csv
      csv.length > 300_000 ? csv.first(300_000) : csv
    end
  end

  # Re-ingesting the same document replaces its previous entries.
  def replace_price_book_entries(result)
    PriceBookItem.where(user: @doc.user, source_kind: "user")
      .where("source = ?", source_tag).delete_all

    rows = result["items"].filter_map do |item|
      next if item["unit_cost"].to_f <= 0
      {
        category: item["category"].presence || "General",
        description: item["description"],
        item_type: EstimateLineItem::ITEM_TYPES.include?(item["item_type"]) ? item["item_type"] : nil,
        uom: item["uom"].presence || "ea",
        unit_cost: item["unit_cost"].to_d,
        sample_count: 1,
        source: source_tag,
        source_kind: "user",
        user_id: @doc.user_id,
        context: @doc.questionnaire,
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    PriceBookItem.insert_all(rows) if rows.any?
  end

  def upsert_template(result)
    names = Array(result["template_sections"]).uniq
    return if names.size < 3

    template = EstimateTemplate.find_or_initialize_by(name: "#{@doc.user.name} — #{@doc.name}")
    template.update!(
      description: "Personal template from training upload '#{@doc.name}'. #{result['project_summary']}".truncate(500),
      sections: names.map { |n| { "name" => n, "hint" => "" } }
    )
  end

  def source_tag
    "training:#{@doc.id}"
  end
end
