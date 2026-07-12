# Ingests a builder's own past estimate (PDF or spreadsheet) into their user
# price book and a personal estimate template. The questionnaire answered at
# upload time is attached as context to every extracted rate, so the
# estimator later knows what this builder's "high-end, sloped block" pricing
# actually looks like.
class TrainingIngestor
  SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[project_summary template_sections category_totals items],
    properties: {
      project_summary: { type: "string", description: "One paragraph: what this estimate covers" },
      template_sections: {
        type: "array", items: { type: "string" },
        description: "The estimate's own section/work-group names, in document order"
      },
      category_totals: {
        type: "array",
        description: "Each category/section's own TOTAL as the document states it (header or subtotal rows) — quoted total, and actual total where the document carries actuals. These are the builder's own carried amounts, used to sanity-check extraction completeness.",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[category quoted_total actual_total],
          properties: {
            category: { type: "string" },
            quoted_total: { type: "number", description: "The section total as quoted/estimated; 0 if not stated" },
            actual_total: { type: "number", description: "The section's actual cost where stated; 0 if none" }
          }
        }
      },
      items: {
        type: "array",
        description: "Every priced line item with a usable unit rate. Skip notes, blanks and $0 lines.",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[category description item_type uom unit_cost quantity quantity_kind],
          properties: {
            category: { type: "string", description: "The section/work group it belongs to" },
            description: { type: "string" },
            item_type: { type: "string", enum: EstimateLineItem::ITEM_TYPES },
            uom: { type: "string" },
            unit_cost: { type: "number", description: "AUD ex. GST per unit as documented" },
            quantity: { type: "number", description: "The ESTIMATED (quoted) quantity for this line — the builder's original takeoff (hours, m2, lm, count). Independent of the pricing rules: even when the unit rate is recorded from actuals or as an Allowance total, quantity records the quoted takeoff. 1 for lump/allowance lines with no real takeoff." },
            quantity_kind: { type: "string", enum: %w[measured lump], description: "'measured' only when the quoted quantity counts real physical units the estimator took off (m2, lm, openings, hours, weeks). 'lump' for allowances, PC/PS sums, packages, and 1-with-a-total lines. Progress-claim style quantities (fractional counts, counts against whole-package descriptions) are 'lump'." }
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

    merged = { "project_summary" => nil, "template_sections" => [], "category_totals" => [], "items" => [] }
    @doc.files.each do |file|
      extraction_units(file).each do |content|
        result = @client.complete_json(
          system: [ { type: "text", text: instructions } ],
          content: content + [ { type: "text", text: "Extract the estimate's sections and priced line items." } ],
          schema: SCHEMA
        )
        merged["project_summary"] ||= result["project_summary"]
        merged["template_sections"] |= Array(result["template_sections"])
        merged["category_totals"] |= Array(result["category_totals"])
        merged["items"].concat(Array(result["items"]))
      end
    end

    replace_price_book_entries(merged)
    verify_entries(merged)
    @doc.update!(status: "completed", extraction: merged.slice("project_summary", "template_sections", "category_totals")
      .merge("item_count" => merged["items"].size))
    QuantityNorms.derive!(@doc.user)
    refresh_template_proposal
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
      dropping its actual quantity. Beware progress-claim quantities: a
      fractional actual quantity (e.g. 9.25), or any quantity against a line
      whose description covers a whole package ("ALL external windows..."),
      counts payments, not physical units — record such lines as ONE
      Allowance at the ACTUAL TOTAL. Only record a per-unit rate when the
      quantity counts real physical units (openings, m2, hours). Where a
      line has no actuals, the quoted total with quantity 1 is the unit rate
      (uom Allowance or ea). CRITICAL uom rule: whenever the number you
      record is a line TOTAL rather than a true per-unit rate, set uom to
      "Allowance" — never leave a per-unit uom (Hour, each, m2, lm) carrying
      a total, or the book will teach a $4,000 painting package as $4,000
      per hour. Sanity-check every entry: a per-unit uom must carry a
      believable per-unit price.

      Two kinds of entries, two different rules:

      RATE entries (a true per-unit price: $/m2, $/hour, $/lm, $/each for a
      countable item): extract EVERY one, always — rate cards, unit prices,
      hourly rates. They record what a unit of work costs, not money spent,
      so they are EXEMPT from reconciliation. Never drop, merge, or skim
      them: a joinery rate card with 30 lines yields 30 entries. These are
      the granular comparables future estimates depend on.

      LUMP entries (Allowance/package totals — money actually spent):
      these reconcile against the category header's actual total. Net out
      reversal/credit pairs (a positive line matched by an equal negative
      means the allowance moved — extract neither, or net them); skip
      zero-actual quote lines whose spend appears in another line's actual;
      never record the same money twice. If your LUMP lines alone sum to
      well above the header's actual, you have double-counted.

      Keep the builder's own section names.
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

  # Deterministic post-ingest verification against the document's own
  # category totals — no external data needed:
  # 1. An entry worth >=80% of its whole category is a ROLLUP (the category
  #    package captured as one line) — flagged so it never binds as a
  #    line-item comparable; a $173k 'overall joinery' allowance stacking on
  #    itemised joinery is how calibration runs inflate.
  # 2. Lump entries summing far above the category's actual are double
  #    counts — largest offenders drop until the category reconciles.
  def verify_entries(merged)
    factor = PriceEscalation.factor(@doc.priced_on)
    # Verification needs ground truth: only categories with ACTUAL totals can
    # convict an entry. A quote-format document (no actuals anywhere) gets no
    # verification at all — its big provisional sums are the builder's
    # quoting anchors, not double-counts, and pruning them guts the book.
    actuals = {}
    Array(merged["category_totals"]).each do |r|
      v = r["actual_total"].to_f
      actuals[r["category"]] = v * factor if v.positive?
    end
    if actuals.empty?
      Rails.logger.info("TrainingIngestor verify: quote-format document, verification skipped for doc #{@doc.id}")
      return
    end

    items = PriceBookItem.from_training_doc(@doc.user, @doc.id)
    flagged = 0
    dropped = 0
    items.group_by(&:category).each do |cat, entries|
      actual = actuals[cat]
      next unless actual && actual > 10_000

      entries.each do |i|
        next unless i.unit_cost.to_f >= actual * 0.8
        i.update!(context: i.context.to_h.merge(
          "category_rollup" => true,
          "note" => "rollup of the whole #{cat} package (~category total) — ceiling reference only, never a line-item comparable"))
        flagged += 1
      end

      lumps = entries.reject { |i| i.context.to_h["category_rollup"] }
                     .select { |i| i.uom.to_s =~ /allowance/i }
                     .sort_by { |i| -i.unit_cost.to_f }
      while lumps.sum { |i| i.unit_cost.to_f } > actual * 1.15 && lumps.size > 1
        doomed = lumps.shift
        doomed.destroy
        dropped += 1
      end
    end
    Rails.logger.info("TrainingIngestor verify: #{flagged} rollups flagged, #{dropped} double-counts dropped for doc #{@doc.id}")
  end

  # Re-ingesting the same document replaces its previous entries.
  def replace_price_book_entries(result)
    PriceBookItem.from_training_doc(@doc.user, @doc.id).delete_all

    factor = PriceEscalation.factor(@doc.priced_on)
    escalation_note = factor == 1.0 ? "" : " | escalated x#{factor} from #{@doc.priced_on.strftime('%Y-%m')}"
    # Package semantics differ by document kind: in a job-costing export with
    # actuals, a lump allowance records SPEND (adopt-or-itemise applies); in a
    # quote-format document it is the builder's quoting ANCHOR for that scope
    # and must stay freely usable.
    has_actuals = Array(result["category_totals"]).any? { |r| r["actual_total"].to_f.positive? }
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
        context: @doc.questionnaire.to_h.merge(
          "qty" => item["quantity"].to_f,
          "qty_kind" => item["quantity_kind"].presence || "lump"
        ).merge(
          has_actuals && item["uom"].to_s.match?(/allowance/i) ? { "package" => "package/lump price at its source scope — ADOPT it for that scope OR itemise the scope, never both" } : {}
        ),
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    PriceBookItem.insert_all(rows) if rows.any?
  end

  # Every completed upload re-synthesizes the user's proposed personal
  # template from ALL their completed uploads (structure learning).
  def refresh_template_proposal
    SynthesizeTemplateJob.perform_later(@doc.user)
  end

  def source_tag
    "training:#{@doc.id}"
  end
end
