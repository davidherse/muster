# Stage 2 of estimate generation: for a batch of template sections, produce
# costed line items grounded in the plan analysis and the historical price book.
class LineItemGenerator
  SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[sections],
    properties: {
      sections: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[name applicable line_items],
          properties: {
            name: { type: "string", description: "Section name, exactly as given" },
            applicable: { type: "boolean", description: "false if this section has no work in this project's scope" },
            line_items: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                required: %w[description item_type uom quantity unit_cost confidence assumptions],
                properties: {
                  description: { type: "string" },
                  item_type: { type: "string", enum: EstimateLineItem::ITEM_TYPES },
                  uom: { type: "string", description: "Unit of measure: m2, m, ea, hour, week, Allowance, etc." },
                  quantity: { type: "number" },
                  unit_cost: { type: "number", description: "AUD ex. GST per unit" },
                  confidence: { type: "string", enum: EstimateLineItem::CONFIDENCES,
                                description: "high: quantity and rate well grounded; medium: reasonable takeoff; low: allowance/guess" },
                  assumptions: { type: "string", description: "Key assumptions behind quantity or rate; empty string if none" }
                }
              }
            }
          }
        }
      }
    }
  }.freeze

  def initialize(estimate, analysis:, client: Ai::Client.new)
    @estimate = estimate
    @analysis = analysis
    @client = client
  end

  # sections: array of {"name" =>, "hint" =>} from the template. Returns parsed hash.
  def call(sections)
    @client.complete_json(
      system: system_blocks,
      content: [ { type: "text", text: request_text(sections) } ],
      schema: SCHEMA
    )
  end

  private

  # The price book is large and shared across every batch call for this
  # estimate — cache it so subsequent batches read it at cache prices.
  def system_blocks
    [
      { type: "text", text: instructions },
      { type: "text", text: "PRICE BOOK — unit rates from this builder\u2019s completed jobs, already indexed to current dollars; use them directly (category | description | type | uom | unit cost AUD ex. GST):\n#{PriceBookItem.reference_text}",
        cache_control: { type: "ephemeral" } }
    ]
  end

  def instructions
    <<~PROMPT
      You are an expert residential construction estimator in Queensland, Australia,
      producing a detailed cost estimate for a builder. You will be given a plan analysis,
      the builder's notes, and a batch of costing sections to complete.

      Rules:
      - Cost every section in the batch. If a section has no work in this project's scope,
        mark it applicable: false with an empty line_items array.
      - Ground unit rates in the price book wherever a comparable item exists \u2014 the
        rates are already indexed to current dollars, so apply them directly, adjusting
        only for quantity and context. For items not in the price book use current
        South-East Queensland market rates.
      - All amounts are AUD ex. GST. These are builder's costs (materials, labour,
        subcontractors, equipment), not client prices.
      - Quantities must come from the plan analysis (areas, counts, storeys). Show your
        working in the assumptions field.
      - Use Mat for materials, Lab for builder's labour (typically $65-$80/hour),
        Sub for subcontract trades, Eq for hire/equipment, MatLab for supply-and-install.
      - Be thorough: real sections typically have 3-15 line items covering supply,
        labour, and sundries separately where the trade splits them.

      Quantity discipline \u2014 the most common estimating failure is lump-sum allowances
      that quietly undercount labour-heavy trades. Derive quantities from the building
      geometry in the analysis, and never collapse a whole trade into one allowance:
      - Painting: use the analysis paint areas (internal_paint_area_m2,
        external_paint_area_m2) x per-m2 rates appropriate to the lining type; VJ/
        tongue-and-groove and character detail is slower and prep-heavy. Painting a
        whole renovated dwelling inside and out is one of the largest trades on a
        character renovation \u2014 cost it from area, never as a single allowance.
      - Windows and doors: take off PER OPENING from the window/door schedule counts
        and glazing_notes. High-spec or oversized units cost multiples of standard ones.
      - Lockup and fixing carpentry: labour scales with envelope and detail \u2014 cladding
        area, eaves, decks (deck_patio_area_m2), trim extent \u2014 not floor area alone.
      - Preliminaries: scale supervision/project management, insurances, and
        certification with duration_months and contract value. Site supervision and PM
        run for the whole build. On renovations of this scale preliminaries typically
        total 8-12% of construction cost \u2014 if yours land well below that, re-check
        what is missing rather than assuming the job is cheap to run.
      - Hire and temporary services: multiply weekly/monthly rates by duration_months,
        not a token few weeks.
      - Cost every entry in special_features explicitly (pool, solar, shutters,
        fireplace etc.) \u2014 in the most appropriate section.
      - Respect finish_level: high_end and luxury jobs use premium rates for joinery,
        fixtures, tiling, and glazing \u2014 check the price book's high-end items rather
        than defaulting to mid-range rates.
    PROMPT
  end

  def request_text(sections)
    section_list = sections.map { |s| "- #{s['name']}: #{s['hint']}" }.join("\n")
    <<~TEXT
      PLAN ANALYSIS:
      #{JSON.pretty_generate(@analysis)}

      #{@estimate.prompt.present? ? "BUILDER'S NOTES:\n#{@estimate.prompt}\n" : ''}
      Produce line items for exactly these sections. The "name" field must be the exact
      section name as written before the colon below \u2014 do not append the description:
      #{section_list}
    TEXT
  end
end
