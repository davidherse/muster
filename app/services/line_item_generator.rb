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

  # The price book leads the system prompt with a cache breakpoint directly
  # after it, so every batch call AND both reviewer passes share one cached
  # copy (identical prefix). Role instructions follow the breakpoint.
  # Batches carry scoped book slices in their requests; the system prompt
  # stays small and stable (cache-friendly).
  def system_blocks
    [ { type: "text", text: instructions, cache_control: { type: "ephemeral" } } ]
  end

  def self.price_book_block(user = nil)
    sections = []
    if user && PriceBookItem.for_user(user).exists?
      sections << "USER PRICE BOOK \u2014 THIS BUILDER'S OWN RATES from their uploaded estimates, with the job context they came from. PREFER these whenever a comparable item exists (category | description | type | uom | unit cost AUD ex. GST | context):\n#{PriceBookItem.reference_text(scope: PriceBookItem.for_user(user), with_context: true)}"
    end
    sections << "BASE PRICE BOOK \u2014 shared rates indexed to current dollars; use when the user book has no comparable (category | description | type | uom | unit cost AUD ex. GST):\n#{PriceBookItem.reference_text(scope: PriceBookItem.base)}"
    { type: "text", text: sections.join("\n\n"), cache_control: { type: "ephemeral" } }
  end

  def instructions
    <<~PROMPT
      You are an expert residential construction estimator in Queensland, Australia,
      producing a detailed cost estimate for a builder. You will be given a plan analysis,
      the builder's notes, and a batch of costing sections to complete.

      Rules:
      - Cost every section in the batch. If a section has no work in this project's scope,
        mark it applicable: false with an empty line_items array.
      - Rate preference order: (1) USER PRICE BOOK entries whose bracketed context
        MATCHES this job (same project class and finish level) \u2014 these are this
        builder\u2019s own rates for exactly this kind of work and are BINDING when a
        comparable exists. (2) Other user book entries. (3) BASE PRICE BOOK.
        (4) Current South-East Queensland market rates only when no book answers.
        When several comparables exist, the context-matched one wins \u2014 never
        average it with rates from different job classes. A comparable book rate
        WINS over your market instinct unless the brief or specification
        explicitly upgrades the spec; this matters most on small jobs, where
        premium assumptions silently double costs the books already answer.
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
        them. A small job should produce a small number of sections. Quantities are
        room-scale: strip-out is trade-days not site-weeks, demolition lives inside
        the trades doing it, and hire/temporary items only appear if the work
        genuinely needs them. This builder\u2019s recorded trade rates already absorb
        incidental strip-out, protection and cleanup \u2014 separate site-preparation
        and cleaning sections on room-scale jobs double-count them; reserve those
        sections for genuine whole-house campaigns.
      - Painting: when the job involves a whole-house repaint, price it from the
        price book's "Whole-house repaint composite" entries \u2014 pick the extent
        class matching the brief (selective / full standard / raise-build-under /
        full heritage) and multiply by floor area; itemise prep and enamel extras
        separately if the scope exceeds the class. For partial scopes, price as
        painter-hours from the analysis paint areas with detail-appropriate
        productivity. Never one lump allowance; never a whole-house repaint priced
        below its composite class.
      - Windows and doors: take off PER OPENING from the window/door schedule counts
        and glazing_notes, splitting NEW/REPLACED from RETAINED strictly by what the
        schedule, demolition plans, and brief show \u2014 make no presumption either
        way. Retained openings carry only repair, hardware, or repaint items, not
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
    scoped = scoped_user_rates(sections)
    base_scoped = scoped_base_rates(sections)
    <<~TEXT
      PLAN ANALYSIS:
      #{JSON.pretty_generate(@analysis)}

      #{@estimate.brief_text.present? ? "BUILDER'S NOTES:\n#{@estimate.brief_text}\n" : ''}
      #{scoped.present? ? "THIS BUILDER'S OWN RATES FOR THESE TRADES (from their uploaded estimates; BINDING where a comparable exists \u2014 do not upgrade the spec beyond them without explicit documentation):\n#{scoped}\n" : ''}
      #{base_scoped.present? ? "BASE BOOK RATES FOR THESE TRADES (shared historical rates with source-job context; use where no user rate compares):\n#{base_scoped}\n" : ''}
      Produce line items for exactly these sections. The "name" field must be the exact
      section name as written before the colon below \u2014 do not append the description:
      #{section_list}
    TEXT
  end

  # Deterministic retrieval: only the book entries whose trade bucket matches
  # this batch's sections, injected straight into the request so the model
  # cannot miss the comparables among 1,500+ book lines. User book first
  # (binding), then the matching base-book slice.
  def scoped_user_rates(sections)
    user = @estimate.user
    return nil unless user
    buckets = batch_buckets(sections)
    entries = PriceBookItem.for_user(user).select { |i| buckets.include?(TradeBucket.for(i.category)) }
    return nil if entries.empty?
    PriceBookItem.reference_text(scope: PriceBookItem.where(id: entries.map(&:id)), with_context: true)
  end

  def scoped_base_rates(sections)
    buckets = batch_buckets(sections)
    entries = PriceBookItem.base.select { |i| buckets.include?(TradeBucket.for(i.category)) }
    return nil if entries.empty?
    PriceBookItem.reference_text(scope: PriceBookItem.where(id: entries.map(&:id)), with_context: true)
  end

  def batch_buckets(sections)
    sections.map { |s| TradeBucket.for(s["name"]) }.uniq
  end
end
