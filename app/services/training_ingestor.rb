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

  # Large spreadsheets are extracted in row chunks (a 600-line estimate can't
  # be emitted in one response); results merge across chunks and files.
  CSV_CHUNK_LINES = 220

  def call
    @doc.update!(status: "processing", error_message: nil)

    merged = { "project_summary" => nil, "template_sections" => [], "items" => [] }
    @doc.files.each do |file|
      extraction_units(file).each do |content|
        result = @client.complete_json(
          system: [ { type: "text", text: instructions } ],
          content: content + [ { type: "text", text: "Extract the estimate's sections and priced line items." } ],
          schema: SCHEMA
        )
        merged["project_summary"] ||= result["project_summary"]
        merged["template_sections"] |= Array(result["template_sections"])
        merged["items"].concat(Array(result["items"]))
      end
    end

    replace_price_book_entries(merged)
    upsert_template(merged)
    @doc.update!(status: "completed", extraction: merged.slice("project_summary", "template_sections")
      .merge("item_count" => merged["items"].size))
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
      numbers. Where the document carries BOTH estimated and actual columns,
      prefer ACTUALS whenever they are non-zero — the book should teach what
      work really cost, not what was quoted. Record each line so that
      quantity x unit_cost reproduces the line's ACTUAL TOTAL: when the
      actuals carry their own quantity and unit rate, use those; when a lump
      or Allowance line shows an actual total, record that total as the unit
      rate with quantity 1 — never record a per-unit actual rate while
      dropping its actual quantity. Where a line has no actuals, the quoted
      total with quantity 1 is the unit rate (uom Allowance or ea). Keep the
      builder's own section names.
    PROMPT
  end

  # Each unit is one AI call's content: a PDF whole, or a chunk of CSV lines.
  def extraction_units(file)
    if file.content_type == "application/pdf"
      [ [ { type: "document", source: { type: "base64", media_type: "application/pdf",
                                        data: Base64.strict_encode64(file.download) } } ] ]
    else
      lines = spreadsheet_to_csv(file).lines
      header = lines.first.to_s
      chunks = lines.drop(1).each_slice(CSV_CHUNK_LINES).to_a
      chunks = [ [] ] if chunks.empty?
      chunks.each_with_index.map do |chunk, i|
        [ { type: "text",
            text: "ESTIMATE SPREADSHEET (#{file.filename}) AS CSV \u2014 part #{i + 1} of #{chunks.size}. Section names may continue from a previous part; use the most recent section heading visible.\n#{header}#{chunk.join}" } ]
      end
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
      .where("source LIKE ?", "#{source_tag}%").delete_all

    factor = PriceEscalation.factor(@doc.priced_on)
    escalation_note = factor == 1.0 ? "" : " | escalated x#{factor} from #{@doc.priced_on.strftime('%Y-%m')}"
    rows = result["items"].filter_map do |item|
      next if item["unit_cost"].to_f <= 0
      {
        category: item["category"].presence || "General",
        description: item["description"],
        item_type: EstimateLineItem::ITEM_TYPES.include?(item["item_type"]) ? item["item_type"] : nil,
        uom: item["uom"].presence || "ea",
        unit_cost: (item["unit_cost"].to_d * factor.to_d).round(2),
        sample_count: 1,
        source: source_tag + escalation_note,
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
