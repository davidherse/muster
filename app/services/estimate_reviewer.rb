# Final pass of estimate generation: reviews the assembled estimate against
# the scope analysis the way a senior estimator checks a takeoff — flagging
# sections that are thin OR padded relative to the documented scope, and
# correcting them with explicit line item changes. Symmetric by design: it is
# told to look for both under- and over-estimation.
class EstimateReviewer
  SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[review_notes metrics_review changes],
    properties: {
      review_notes: { type: "string", description: "Brief summary of what the review found" },
      metrics_review: {
        type: "array",
        description: "One entry PER computed intensity metric provided — every metric must be explicitly adjudicated",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[metric in_band action],
          properties: {
            metric: { type: "string", description: "Which metric (short name)" },
            in_band: { type: "boolean", description: "Is it inside its stated norm band / SEQ norms for this job?" },
            action: { type: "string", description: "If out of band: the correction made (must appear in changes) or the documented cause for leaving it. If in band: 'ok'" }
          }
        }
      },
      changes: {
        type: "array",
        description: "Corrections. Empty if the estimate is sound.",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[section reason remove_descriptions add_items],
          properties: {
            section: { type: "string", description: "Exact section name being corrected" },
            reason: { type: "string", description: "Why: what scope is missing, double-counted, or mis-quantified" },
            remove_descriptions: {
              type: "array", items: { type: "string" },
              description: "Exact descriptions of existing line items to delete (for over-counted or superseded items)"
            },
            add_items: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                required: %w[description item_type uom quantity unit_cost confidence assumptions],
                properties: {
                  description: { type: "string" },
                  item_type: { type: "string", enum: EstimateLineItem::ITEM_TYPES },
                  uom: { type: "string" },
                  quantity: { type: "number" },
                  unit_cost: { type: "number", description: "AUD ex. GST per unit" },
                  confidence: { type: "string", enum: EstimateLineItem::CONFIDENCES },
                  assumptions: { type: "string" }
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

  # Adversarial dual review: a completeness prosecutor (hunts missing/thin
  # scope) then a padding prosecutor (hunts invented scope, double counts,
  # over-spec) on the corrected estimate. Opposed mandates beat one balanced
  # pass, which tended to rubber-stamp.
  def call
    notes = []
    corrections = {}
    [ :completeness, :padding ].each do |direction|
      result = @client.complete_json(
        system: [ LineItemGenerator.price_book_block(@estimate.user), { type: "text", text: instructions(direction) } ],
        content: [ { type: "text", text: request_text } ],
        schema: SCHEMA
      )
      added, removed = apply(result)
      corrections[direction] = { added: added.round, removed: removed.round }
      notes << "#{direction}: #{result['review_notes']}"
    end
    { notes: notes.join(" | "), corrections: corrections }
  end

  private

  def instructions(direction)
    common = <<~COMMON
      You are a senior residential construction estimator in Queensland, Australia,
      auditing an estimate prepared from the attached scope analysis. Every
      correction must cite the specific analysis quantity, schedule entry, or brief
      statement that justifies it in its reason. A correction you cannot tie to a
      documented fact is not allowed. If nothing qualifies, return an empty changes
      list — that is a good outcome.

      MATERIALITY: return at most the 12 most material corrections, largest dollar
      impact first, and ignore anything whose total effect is under $1,000 — a
      senior reviewer fixes what moves the price, not every nit. Keep reasons to
      one sentence. A correction replaces or adds at most 6 line items — when a
      section needs wholesale re-pricing, correct only its most material lines
      rather than rewriting it; keep assumptions to one short clause. You are
      reviewing an estimate, not re-estimating the job. Keep unit rates consistent with the rates already used
      elsewhere in the estimate. All amounts AUD ex. GST, builder's costs.
    COMMON

    case direction
    when :completeness
      common + <<~PROMPT
        Your mandate: find what is MISSING or UNDERDONE. You are not allowed to
        remove or reduce anything. Additions must be priced at recorded PRICE BOOK
        rates where a comparable exists — a completeness correction is not a
        license for market instinct. Hunt for:
        - features in the analysis or brief with no line items at all
        - quantities inconsistent with documented areas/counts (paint priced below
          the stated paint area, fewer openings than the schedule, hire not
          carried for the stated duration)
        - trades the documented scope requires but no section covers
        - takeoff entries treated as trade ceilings: drawn new-work quantities
          (an extension's sheeting, a new slab) capping documented rework of
          retained fabric on character renovations — the rework is additional
        - structure, footings, raising, scaffold or external works priced at
          base-book flat-site allowances despite documented extreme site
          conditions (steep slope, deep engineered piers, extreme raise
          height, difficult access) — rebuild from the documented engineering
          quantities
        - builder-confirmed scope with no line items ANYWHERE: every
          structural_work / systems_extras / external_works item in the
          builder's brief (pool, house raise, retaining walls, solar) must be
          costed — a missing pool or raise is the single worst omission
        - analysis special_features entries (shutters, fireplaces, lifts,
          stained glass, pools) with no line items anywhere — documented
          features do not become free by being unusual
        - allowance-type comparables adopted at face value where this job's
          documented geometry (opening counts and glazing_notes, envelope area,
          storeys, retained-structure intensity) exceeds the scope the
          comparable's description and context imply — scale them to the
          documented geometry and check the computed per-opening and per-m2
          metrics against SEQ norms for this finish level and building type
      PROMPT
    when :padding
      common + <<~PROMPT
        Your mandate: find what is INVENTED or OVERDONE. You are not allowed to add
        scope; only remove or right-size (remove + re-add corrected). Hunt for:
        - items for work the documents show as retained or excluded, or that the
          brief assigns to others
        - the same work costed in two sections (e.g. waterproofing in both its own
          section and tiling; demolition in two places)
        - quantities exceeding the documented geometry, retained openings priced
          as new supply, sections irrelevant to this project_class carrying token
          items, trades upgraded beyond the specified finish level
        - quantities departing from an analysis quantity_takeoff entry that
          carries dimension-level working, in either direction without
          documented cause — but the ABSENCE of a takeoff entry is never
          grounds to trim a trade; sparse takeoffs on complex plan sets say
          nothing about the work
        - wet-area tiling/waterproofing quantities above the analysis
          wet_area_takeoff m2 figures (check the wet-areas metric), or priced at
          premium PC allowances where the book carries a room-scoped rate and
          the specification documents no upgrade
        - on raise/build-in-under jobs: a demolition/site campaign duplicating
          strip-out and stump work the raising and structural trades already
          carry in their rates
        - a repaint composite class unsupported by evidence in either direction:
          era alone does not make a heritage repaint, but documented heritage
          fabric across the repaint scope does — verify the painting $/m2 metric
          against the class the documented fabric supports before correcting
        - supervision/PM hours outside this builder's documented 8-11 hours/week
          band (check the computed metrics) without documented heavy-character
          complexity; statutory levies and insurance premiums computed on this
          estimate's own inflated total instead of the documented scope's value
        - lump-sum allowances adopted from a comparable whose source scope is far
          larger than this job (a whole-house supply allowance carried into
          room-scale work) — recompute from this job's measured quantities at a
          unit rate derived from the comparable
        - unit rates materially above a comparable PRICE BOOK item without an
          explicit spec justification \u2014 check every large line against the price
          book; the builder\u2019s own recorded rate wins over market instinct
          (cite the price book entry in your reason when you correct a rate)
      PROMPT
    end
  end

  def request_text
    <<~TEXT
      SCOPE ANALYSIS:
      #{JSON.pretty_generate(@analysis)}

      #{@estimate.brief_text.present? ? "BUILDER'S BRIEF:\n#{@estimate.brief_text}\n" : ''}
      COMPUTED INTENSITY METRICS \u2014 these are NORMATIVE, not advisory: where a
      metric falls outside the norm band stated with it (or outside SEQ market
      norms for this finish level and building type) and the documents show no
      cause, you MUST correct the driving section back into the band at book
      rates. Leaving an out-of-band metric uncorrected without citing its
      documented cause is a review failure in EITHER direction:
      #{metrics_text}

      THE ESTIMATE TO REVIEW:
      #{estimate_text}
    TEXT
  end

  def metrics_text
    total = @estimate.line_items.sum { |i| i.total.to_f }
    floor = @analysis["floor_area_m2"].to_f
    months = @analysis["duration_months"].to_f
    paint_area = @analysis["internal_paint_area_m2"].to_f + @analysis["external_paint_area_m2"].to_f
    windows = @analysis["window_count"].to_i + @analysis["external_door_count"].to_i

    section_total = ->(name) do
      @estimate.sections.select { |s| s.name.downcase.include?(name) }.sum { |s| s.subtotal.to_f }
    end
    pm_hours = @estimate.line_items
      .select { |i| i.item_type == "Lab" && i.uom.to_s.downcase.include?("hour") && i.description.to_s =~ /supervis|project manage|coordinat/i }
      .sum { |i| i.quantity.to_f }

    lines = []
    lines << "- Construction total: $#{total.round} => $#{floor.positive? ? (total / floor).round : '?'} per m2 floor area (#{floor.round} m2)"
    lines << "- Estimated duration: #{months} months"
    paint = section_total.call("paint")
    lines << "- Painting section: $#{paint.round} over #{paint_area.round} m2 paint area => $#{paint_area.positive? ? (paint / paint_area).round : '?'} per m2 (supply+apply all coats)"
    win = section_total.call("window")
    lines << "- Windows and doors: $#{win.round} across #{windows} openings => $#{windows.positive? ? (win / windows).round : '?'} per opening"
    lines << "- Supervision/PM hours: #{pm_hours.round} total => #{months.positive? ? (pm_hours / (months * 4.33)).round(1) : '?'} hours/week over the build"
    prelim = section_total.call("preliminar")
    lines << "- Preliminaries section: $#{prelim.round}"
    takeoff = Array(@analysis["wet_area_takeoff"])
    if takeoff.any?
      wet = section_total.call("tiling") + section_total.call("waterproof")
      floor_m2 = takeoff.sum { |r| r["floor_m2"].to_f }
      wall_m2 = takeoff.sum { |r| r["wall_tile_m2"].to_f }
      lines << "- Wet areas: tiling+waterproofing $#{wet.round} against takeoff #{floor_m2.round} m2 floor + #{wall_m2.round} m2 wall across #{takeoff.size} room(s) — quantities above these takeoff figures are unsupported"
    end
    if %w[partial_interior_renovation small_works].include?(@analysis["project_class"])
      rooms = [ @analysis["wet_area_count"].to_i, Array(@analysis["rooms"]).size, 1 ].reject(&:zero?).min
      lines << "- Partial job: $#{(total / rooms).round} per renovated room across #{rooms} room(s)"
      elec = section_total.call("electrical")
      lines << "- Electrical: $#{elec.round} => $#{(elec / rooms).round} per room (SEQ wet-area reno norm: rough-in + fit-off runs $1,200-1,800/room standard, to ~$2,500 only with documented extras; PC fittings priced separately count within this check)" if elec.positive?
      demo = section_total.call("site preparation") + section_total.call("demolition")
      lines << "- Demo/strip-out: $#{demo.round} => $#{(demo / rooms).round} per room (strip-out of one wet area is 2-3 trade-days plus disposal — more needs documented cause)" if demo.positive?
      labour_hours = @estimate.line_items
        .select { |i| %w[Lab Sub].include?(i.item_type) && i.uom.to_s.downcase.include?("hour") }
        .sum { |i| i.quantity.to_f }
      site_days = (months * 21.7).round
      lines << "- Implied on-site labour: #{(labour_hours / 8).round} trade-days against ~#{site_days} working days of stated duration \u2014 does the crew size implied make sense for rooms this size?"
    end
    violations = computed_violations(section_total, pm_hours, months)
    if violations.any?
      lines << ""
      lines << "OUT-OF-BAND \u2014 these are computed violations, not opinions. Each REQUIRES a correction in changes (re-priced at book rates to within its band), unless the documents show specific cause, which the metrics_review action must cite:"
      violations.each { |v| lines << "  * #{v}" }
    end
    lines.join("\n")
  end

  # Deterministic norm checks: Ruby decides what is out of band so engagement
  # is not left to the model's judgment. Bands are the documented ones the
  # prompts already state (supervision from this builder's five recorded jobs;
  # per-room norms are standing SEQ figures for wet-area renovations).
  def computed_violations(section_total, pm_hours, months)
    violations = []
    if months.positive? && pm_hours.positive?
      hrs_wk = pm_hours / (months * 4.33)
      violations << "Supervision #{hrs_wk.round(1)} hrs/week is outside this builder's documented 8-11 band (18 for heavy-character)" if hrs_wk > 12.5 || hrs_wk < 6
    end
    if %w[partial_interior_renovation small_works].include?(@analysis["project_class"])
      rooms = [ @analysis["wet_area_count"].to_i, Array(@analysis["rooms"]).size, 1 ].reject(&:zero?).min
      elec = section_total.call("electrical")
      violations << "Electrical $#{(elec / rooms).round}/room exceeds the $2,500/room high-end ceiling" if elec / rooms > 2_500
      demo = section_total.call("site preparation") + section_total.call("demolition")
      violations << "Demo/strip-out $#{(demo / rooms).round}/room exceeds the ~$2,800/room ceiling (2-3 trade-days plus disposal)" if demo / rooms > 2_800
      takeoff = Array(@analysis["wet_area_takeoff"])
      if takeoff.any?
        wet = section_total.call("tiling") + section_total.call("waterproof")
        area = takeoff.sum { |r| r["floor_m2"].to_f + r["wall_tile_m2"].to_f }
        violations << "Tiling+waterproofing $#{(wet / area).round}/m2 over the takeoff area exceeds ~$330/m2 (supply + lay + screed + waterproof, quality wet-area rates)" if area.positive? && wet / area > 330
      end
    end
    violations
  end

  def estimate_text
    @estimate.sections.includes(:line_items).map do |section|
      items = section.line_items.map do |i|
        "  - #{i.description} | #{i.item_type} | #{i.quantity&.to_f} #{i.uom} @ $#{i.unit_cost&.to_f} = $#{i.total&.to_f} (#{i.confidence})"
      end
      "#{section.name} — subtotal $#{section.subtotal.to_f.round}\n#{items.join("\n")}"
    end.join("\n\n")
  end

  # Returns [dollars added, dollars removed] so the assessor can weigh
  # omission risk (additions) against over-pricing risk (removals).
  def apply(result)
    added = 0.0
    removed = 0.0
    result.fetch("changes", []).each do |change|
      # Fuzzy-match paraphrased section names ("Demolition (strip-out)" for
      # "Site Preparation and Demolition") before creating a near-duplicate.
      wanted = change["section"].to_s
      section = @estimate.sections.find_by(name: wanted) ||
                @estimate.sections.detect { |s|
                  a = s.name.downcase.gsub(/[^a-z ]/, "").strip
                  b = wanted.downcase.gsub(/[^a-z ]/, "").strip
                  a.start_with?(b) || b.start_with?(a)
                } ||
                @estimate.sections.create!(name: wanted,
                                           position: (@estimate.sections.maximum(:position) || 0) + 1)

      change.fetch("remove_descriptions", []).each do |desc|
        doomed = section.line_items.where(description: desc)
        removed += doomed.sum { |i| i.total.to_f }
        doomed.destroy_all
      end

      next_position = (section.line_items.maximum(:position) || 0)
      change.fetch("add_items", []).each do |item|
        next_position += 1
        added += item["quantity"].to_d * item["unit_cost"].to_d
        section.line_items.create!(
          position: next_position,
          description: item["description"],
          item_type: EstimateLineItem::ITEM_TYPES.include?(item["item_type"]) ? item["item_type"] : nil,
          uom: item["uom"],
          quantity: item["quantity"].to_d,
          unit_cost: item["unit_cost"].to_d,
          total: (item["quantity"].to_d * item["unit_cost"].to_d).round(2),
          confidence: EstimateLineItem::CONFIDENCES.include?(item["confidence"]) ? item["confidence"] : "medium",
          assumptions: [ item["assumptions"].presence, "Added in review: #{change['reason']}" ].compact.join(" — ")
        )
      end

      section.reload
      section.destroy if section.line_items.none?
    end
    [ added, removed ]
  end
end
