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
    if PriceBookItem.market.exists?
      sections << "PUBLISHED MARKET REFERENCE \u2014 Archicentre Australia bands, ex GST, consumer prices incl builder margin at standard finishes; sanity bounds only, never preferred over recorded rates (category | description | uom | midpoint | context with band_low/band_high):\n#{PriceBookItem.reference_text(scope: PriceBookItem.market, with_context: true)}"
    end
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
      - BUILDER-CONFIRMED SCOPE IS BINDING BOTH WAYS: every structural_work,
        systems_extras and external_works item in the BUILDER'S NOTES (pool,
        house raise, retaining walls, solar, A/C) MUST be costed in its section \u2014
        never mark such a section inapplicable or return it empty. Conversely,
        never cost a pool, raise, or similar major feature that neither the
        documents nor the builder's notes support.
      - LABOUR HOURS ANCHOR TO THE BUILDER'S OWN LINES \u2014 DERIVE, NEVER COPY:
        user-book hour entries carry the builder's original takeoff in their
        context tags (qty: their quoted hours). A comparable's hours belong to
        ITS job's scope, so copying them is wrong whenever the scope differs \u2014
        which is almost always. The procedure for every Lab/hours line:
        (1) find the comparable hour line for the SAME ACTIVITY AND SAME VERB \u2014
        a set-out line anchors set-out, an install line anchors install, never
        cross them; (2) find that comparable's scope denominator in its
        SIBLING book lines from the same category/job (their decking-supply
        m2 next to their decking-install hours, their steel member/tonnage
        lines next to their steel-fit hours) and derive the productivity
        (hours per m2/lm/member); (3) multiply by THIS job's quantity for
        that activity from the analysis takeoff. State all three steps in
        assumptions ("their 72h install \u00f7 60m2 deck = 1.2h/m2 \u00d7 25m2 here =
        30h"). When no sibling denominator exists, scale by the most honest
        measure available and say which; when the book has no comparable
        activity at all, free-read and mark low confidence. Crew-time
        optimism and pessimism are both errors: the builder's own quoted
        productivity is the target, not what a generic crew might achieve.
      - EVERY measured quantity (m2, lm, ea, Hour) must show its takeoff
        working in assumptions: the plan dimensions it derives from, the
        takeoff entry it cites, or the comparable-scaling arithmetic. A
        measured quantity with no working is a review failure.
      - Wet areas: tiling and waterproofing quantities come STRICTLY from the
        analysis wet_area_takeoff rooms (floor_m2 / wall_tile_m2) \u2014 never from
        your own re-reading of the plans and never rounded up. Cite the takeoff
        room in assumptions.
      - Measured trades: where the analysis quantity_takeoff carries an entry
        for the work (floor coverings, slabs/concrete, retaining, decking,
        cladding, driveway), its QUANTITY is binding — price that quantity at
        the book rate and cite the entry. The takeoff pins quantities for the
        trades it lists and NOTHING more: trades without an entry are costed
        exactly as they always would be, from the analysis geometry and the
        book — a missing takeoff entry is never a reason to shrink, thin, or
        omit normal scope. A takeoff entry binds only the work its DESCRIPTION
        covers: "new roof sheeting — extension" pins the extension's sheeting,
        not the roofing trade — documented rework of RETAINED fabric
        (re-roofing, re-framing, restumping, character repair per the scope
        summary, structural notes and retained-scope notes) is costed IN
        ADDITION to drawn new-work entries. A "by others" note in a takeoff
        basis does not remove work the BUILDER'S NOTES confirm as included —
        the builder's stated scope outranks drawing notes; cost it and record
        the conflict in assumptions.
      - Package adoption is exclusive: when a bound comparable is a package or
        lump allowance covering a scope (a plumbing package, a stone benchtop
        provisional, a roofing package), adopting it REPLACES itemised buildup
        for that scope — pricing the package AND itemising its contents is
        double counting, the classic way a builder's own uploaded rates
        inflate their next estimate. Adopt the package where it matches the
        scope; itemise only what the package excludes, and say so.
      - Services on room-scale scopes: electrical and plumbing price from the
        book's recorded rates (per m2, per point, per hour, or a recorded
        room allowance) applied to this job's takeoff quantities and fixture
        counts. Never invent a per-room lump "rough-in and fit-off" allowance
        the book does not record — that is market instinct wearing a
        quantity's clothes.
      - PC allowances are the BUILDER'S OWN recorded levels: a PC (prime cost)
        allowance is a budget this builder sets for client-selected items —
        tiles, fittings, fixtures — and the book records this builder's
        standard levels per room type. Use those recorded levels regardless of
        how premium the designer's selections look; a selection exceeding the
        PC allowance becomes a client variation, not a bigger estimate. Only a
        specification that NAMES a product with a stated price moves a PC
        allowance, and then to that stated price.
      - Rate preference within the book: a rate scoped to the same room or work
        type (e.g. a per-bathroom tile supply rate for bathroom work) BEATS any
        generic or premium allowance, whatever their relative prices. Premium PC
        allowances apply only where the specification documents that upgrade for
        this job.
      - Documented site intensity: where the brief or analysis documents steep
        slope, difficult access, deep engineered footings, or an extreme raise
        height, the affected trades (raising, piering/footings, structural
        steel and carpentry, scaffold and crane access, external works) must be
        built up from the DOCUMENTED engineering quantities — pier count x
        depth, raise height, scaffold lifts — at rates befitting those
        conditions. The book's rates carry their source job's conditions (see
        context tags): a flat-block raise allowance adopted unadjusted onto a
        documented steep-site extreme-height raise under-prices it, exactly as
        a whole-house allowance over-prices a bathroom. Site intensity scales
        the RAISING, footing, access and structural trades only. ON RAISE/
        BUILD-UNDER JOBS ONLY: demolition and site-prep never grow on account
        of site conditions and stay limited to documented removals. This
        clause says nothing about demolition on any other job class — cost
        those normally from the documented demolition scope.
      - Raise / build-in-under jobs: under-house strip-out, stump removal and
        making-good are within the raising and structural carpentry scope the
        book's rates already carry \u2014 the demolition section covers only
        documented removals beyond that (finishes, partitions, roofing). Do not
        run a second whole-site demolition campaign alongside a raise.
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
      - Comparable scale: a price book entry priced as "Allowance" records a lump
        sum for ITS source job's scope — often a whole house. Lump sums do not
        transfer across job sizes. Before reusing one on a job of different scope,
        derive a unit rate from it (allowance ÷ the scope its description and
        context imply) and apply that rate to THIS job's measured quantities — or
        ignore it and build the item up from quantities and trade rates. A
        room-scale job must not inherit any single line at whole-house scale
        (whole-house tile supply, house rewire, kitchen-grade joinery allowances on
        a vanity); equally, never scale a small allowance up to whole-house without
        geometry to support it. Show the derivation in assumptions whenever you
        scale a comparable.
      - Painting: when the job involves a whole-house repaint, price it from the
        price book's "Whole-house repaint composite" entries multiplied by the
        analysis floor_area_m2 exactly (all levels in scope — never re-measure
        or re-scope the area) \u2014 pick the extent
        class matching the brief (selective / full standard / raise-build-under /
        full heritage) and multiply by floor area; itemise prep and enamel extras
        separately if the scope exceeds the class. The class is COMPUTED and
        given in the request as REPAINT COMPOSITE CLASS — use exactly that
        composite entry; never re-derive or upgrade it. State the class and
        resulting $/m2 in assumptions; never cost tile/wall areas in both
        painting and another trade. For partial scopes, price as
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
    section_list = sections.map do |s|
      line = "- #{s['name']}: #{s['hint']}"
      typical = Array(s["typical_items"])
      if typical.any?
        line += "\n  This builder typically itemises this section as (match their breakdown and wording where the scope applies): #{typical.join('; ')}"
      end
      line
    end.join("\n")
    scoped = scoped_user_rates(sections)
    paint_class = repaint_class
    base_scoped = scoped_base_rates(sections)
    norms = norms_text(sections)
    market_scoped = scoped_market_rates(sections)
    <<~TEXT
      PLAN ANALYSIS:
      #{JSON.pretty_generate(@analysis)}

      #{@estimate.brief_text.present? ? "BUILDER'S NOTES:\n#{@estimate.brief_text}\n" : ''}
      #{scoped.present? ? "THIS BUILDER'S OWN RATES FOR THESE TRADES (from their uploaded estimates; BINDING where a comparable exists \u2014 do not upgrade the spec beyond them without explicit documentation):\n#{scoped}\n" : ''}
      #{base_scoped&.dig(:matched).present? ? "BASE BOOK RATES — BINDING where a comparable exists (recorded same-class rates, plus unit-priced rates from all of this builder's jobs: unit rates transfer across job sizes — apply them to THIS job's quantities). Prefer same-class entries, then unit-priced entries; resort to market instinct only where the book has no comparable, and flag those lines low confidence. Do not upgrade the spec beyond recorded rates without explicit documentation:\n#{base_scoped[:matched]}\n" : ''}
      #{base_scoped&.dig(:other).present? ? "BASE BOOK LUMP-SUM ALLOWANCES FROM OTHER JOB CLASSES (advisory — derive a unit rate per each entry's context and scale to this job before any use):\n#{base_scoped[:other]}\n" : ''}
      #{market_scoped.present? ? "PUBLISHED MARKET REFERENCE (Archicentre Australia, cited; consumer prices ex GST incl builder margin, standard finishes — use ONLY where neither book answers, as sanity bounds: builder cost normally lands under these; documented premium spec may exceed them):\n#{market_scoped}\n" : ''}
      #{paint_class ? "REPAINT COMPOSITE CLASS (computed from the builder's stated extent and the job class — use the book's '#{paint_class}' composite; do not re-derive the class): #{paint_class}\n" : ''}
      #{norms.present? ? "#{norms}\n" : ''}
      Produce line items for exactly these sections. The "name" field must be the exact
      section name as written before the colon below \u2014 do not append the description:
      #{section_list}
    TEXT
  end

  # The repaint composite class is computed, not chosen — the model kept
  # oscillating between defensible readings (raise vs heritage) on jobs that
  # are both. Raise/build-under jobs use their own composite; heritage needs
  # stated character fabric in the extent AND a character-era building.
  def repaint_class
    q = @estimate.questionnaire.to_h
    extent = q["repaint_extent"].to_s
    return nil if extent.blank? || extent =~ /\bnone\b/i
    return "selective scope" if extent =~ /selective|partial|new work/i
    if @analysis["project_class"] == "raise_and_build_under"
      "full repaint incl raise/build-under new lower level"
    elsif extent =~ /VJ|fretwork|character|heritage/i &&
          (q["building_era"].to_s =~ /1946|character/i ||
           @analysis["internal_lining_type"].to_s =~ /VJ|tongue|T&G|board/i)
      "full heritage repaint"
    else
      "full repaint of standard character home"
    end
  end

  # The builder's own quantity norms for this batch's trades, scaled to this
  # job's works area. Quantities — especially labour hours — are where AI
  # estimates diverge most from human takeoffs, and every builder crews work
  # differently; their own past jobs are the best predictor.
  def norms_text(sections)
    norms = QuantityNorms.for_class(@estimate.user, @analysis["project_class"])
    return nil unless norms
    area = @analysis["floor_area_m2"].to_f
    return nil unless area.positive?

    buckets = batch_buckets(sections)
    lines = buckets.flat_map do |bucket|
      (norms.dig("buckets", bucket) || {}).filter_map do |uom, s|
        expected = (s["per_m2"].to_f * area).round
        next if expected.zero?
        spread = s["n"].to_i > 1 ? " (range #{(s['min'].to_f * area).round}–#{(s['max'].to_f * area).round} across #{s['n']} jobs)" : ""
        "  - #{bucket}: ~#{expected} #{uom} total across the trade for this #{area.round} m2 job#{spread}"
      end
    end
    if buckets.include?("preliminaries") && (sup = norms["supervision_hours_per_week"])
      lines << "  - supervision/project management: ~#{sup['value']} hours per week#{sup['n'].to_i > 1 ? " (their range #{sup['min']}–#{sup['max']} h/wk)" : ''}"
    end
    return nil if lines.empty?

    <<~TEXT.strip
      THIS BUILDER'S QUANTITY NORMS — takeoff intensities from their own past jobs of this class, scaled to this job's works area. Labour hours and measured quantities should land near these totals unless the documents show cause; when your takeoff differs by more than ~30%, re-check the takeoff before keeping it:
      #{lines.join("\n")}
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
    entries = PriceBookItem.for_user(user)
                           .reject { |i| i.context.to_h["category_rollup"] }
                           .select { |i| buckets.include?(TradeBucket.for(i.category)) }
    return nil if entries.empty?
    PriceBookItem.reference_text(scope: PriceBookItem.where(id: entries.map(&:id)), with_context: true)
  end

  # Returns { matched:, other: } — base entries whose source-job class matches
  # this job carry the same authority as user rates; the rest are advisory
  # references to be adjusted for class and scale.
  def scoped_base_rates(sections)
    buckets = batch_buckets(sections)
    entries = PriceBookItem.base.select { |i| buckets.include?(TradeBucket.for(i.category)) }
    return nil if entries.empty?
    klass = @analysis["project_class"]
    # Same-class entries bind wholesale. Unit-priced entries (ea/m2/hour/etc.)
    # bind across classes too — unit rates transfer across job sizes; lump-sum
    # allowances from other classes stay advisory.
    matched, other = entries.partition do |i|
      (klass.present? && i.context["project_class"] == klass) ||
        i.uom.to_s.match?(/\A(m2|m|ea|each|hour|hr|week|no|item|point|lm)\z/i)
    end
    {
      matched: matched.any? ? PriceBookItem.reference_text(scope: PriceBookItem.where(id: matched.map(&:id)), with_context: true) : nil,
      other: other.any? ? PriceBookItem.reference_text(scope: PriceBookItem.where(id: other.map(&:id)), with_context: true) : nil
    }
  end


  def scoped_market_rates(sections)
    buckets = batch_buckets(sections)
    entries = PriceBookItem.market.select { |i| buckets.include?(TradeBucket.for(i.category)) }
    return nil if entries.empty?
    PriceBookItem.reference_text(scope: PriceBookItem.where(id: entries.map(&:id)), with_context: true)
  end

  def batch_buckets(sections)
    sections.map { |s| TradeBucket.for(s["name"]) }.uniq
  end
end
