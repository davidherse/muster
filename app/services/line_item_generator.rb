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

      Quantity discipline \u2014 the two classic estimating failures are lump-sum
      allowances that undercount labour-heavy trades, and padding that prices work
      the plans do not show. Quantities must come from the analysis geometry \u2014 no
      more, no less:
      - Scope boundaries: cost ONLY work shown in the plans/brief. Respect
        retained_scope_notes \u2014 retained rooms, roof, cladding or structure get no
        line items. Do not add contingency padding to quantities or rates.
      - Partial-scope jobs: when the brief describes work limited to specific rooms
        or areas (e.g. a bathroom/ensuite renovation), whole-house sections \u2014 site
        establishment, temporary services, hire and scaffolding, external trades,
        framing/structure, roofing \u2014 are NOT applicable unless the documents show
        that work. Mark them applicable: false; do not find token items to fill
        them. A small job should produce a small number of sections.
      - Painting: this trade is priced as PAINTER-HOURS (the price book carries
        hourly painter rates). Estimate hours from the analysis paint areas and
        realistic productivity: straightforward new plasterboard walls paint fast;
        repaint prep, VJ/tongue-and-groove, trim/window/door enamel work, and
        character detail are several times slower per m2. Cost internal, external,
        and trim/openings enamel as separate labour items plus materials, never one
        allowance. Sanity-check the result: hours x rate should reflect a crew on
        site for weeks on a whole-house repaint, not days.
      - Windows and doors: take off PER OPENING from the window/door schedule counts
        and glazing_notes, and distinguish NEW or REPLACED openings from RETAINED
        ones (retained_scope_notes and the elevations show which is which \u2014 on
        raise/build-under and renovation jobs most upper-level openings are usually
        kept). Retained openings carry only repair, hardware, or repaint items, not
        supply+install. High-spec or oversized new units cost multiples of standard.
      - Lockup and fixing carpentry: labour scales with new envelope and detail \u2014
        new cladding area, eaves, decks (deck_patio_area_m2), trim extent.
      - Preliminaries: itemise explicitly \u2014 insurance premiums scale with contract
        value, certification and engineering fees per the scope, and supervision/
        project management as hours per week x duration_months at the price book
        rate. This builder runs owner-led supervision: historical jobs from \$85k
        to \$1.1M consistently record ~8-11 supervision hours per week for the
        build duration \u2014 scale supervision with duration, not contract value.
        No percentage targets; build it item by item like the price book does.
      - Hire and temporary services: weekly/monthly rates x the portion of
        duration_months each item is actually on site.
      - Cost every entry in special_features explicitly (pool, solar, shutters,
        fireplace etc.) \u2014 in the most appropriate section.
      - Risk allowances must be VISIBLE: if the brief calls for latent conditions
        or similar contingency, cost it as its own clearly-labelled line item
        (e.g. "Latent conditions allowance \u2014 pre-1947 structure") in the most
        relevant section \u2014 never by quietly inflating other trades. The builder
        must be able to see and strip it when quoting tight.
      - Respect finish_level both ways: high_end jobs use premium rates for joinery,
        fixtures, tiling and glazing; but do not upgrade trades the brief leaves
        standard.
    PROMPT
  end

  def request_text(sections)
    section_list = sections.map { |s| "- #{s['name']}: #{s['hint']}" }.join("\n")
    <<~TEXT
      PLAN ANALYSIS:
      #{JSON.pretty_generate(@analysis)}

      #{@estimate.brief_text.present? ? "BUILDER'S NOTES:\n#{@estimate.brief_text}\n" : ''}
      Produce line items for exactly these sections. The "name" field must be the exact
      section name as written before the colon below \u2014 do not append the description:
      #{section_list}
    TEXT
  end
end
