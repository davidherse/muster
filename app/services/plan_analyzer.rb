# Stage 1 of estimate generation: read the architectural plan PDF and the
# user's brief, and produce a structured scope-of-works analysis that the
# line item generator works from (so the PDF is only sent to the model once).
class PlanAnalyzer
  # Base64 inflates ~4/3; PDFs bigger than this go via the Files API instead
  # of inline base64 (32 MB request limit).
  MAX_INLINE_PDF_BYTES = 20.megabytes
  # API limit for 1M-context models.
  MAX_PDF_PAGES = 600

  SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[project_class relevant_sections building_type storeys floor_area_m2 scope_summary rooms wet_area_count wet_area_takeoff quantity_takeoff
                 window_count external_door_count roof_type external_cladding
                 structural_notes site_notes inclusions exclusions
                 finish_level internal_lining_type external_repaint glazing_notes
                 internal_paint_area_m2 external_paint_area_m2 duration_months
                 retained_scope_notes deck_patio_area_m2 special_features],
    properties: {
      project_class: {
        type: "string",
        enum: %w[new_build whole_house_renovation raise_and_build_under extension_and_renovation
                 partial_interior_renovation small_works],
        description: "What kind of job this is. partial_interior_renovation = work limited to specific rooms (e.g. bathrooms/kitchen); small_works = minor jobs under ~3 months"
      },
      relevant_sections: {
        type: "array", items: { type: "string" },
        description: "From the COSTING SECTIONS list provided, the sections this project actually needs. For whole-house classes include everything plausibly involved; for partial/small jobs list only sections with real work"
      },
      building_type: { type: "string", description: "e.g. New double storey dwelling, Renovation and extension of existing Queenslander" },
      storeys: { type: "integer" },
      floor_area_m2: { type: "number", description: "Total finished floor area of works summed over ALL levels in scope, including new build-under/extension levels (the whole-house composites multiply this figure); estimate from plans if not stated" },
      scope_summary: { type: "string", description: "Detailed narrative of the full scope of works, 2-4 paragraphs" },
      rooms: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[name level notes],
          properties: {
            name: { type: "string" },
            level: { type: "string" },
            notes: { type: "string", description: "Finishes, fixtures, or works noted for this room; empty string if none" }
          }
        }
      },
      wet_area_count: { type: "integer", description: "Bathrooms, ensuites, laundries, WCs requiring waterproofing" },
      quantity_takeoff: {
        type: "array",
        description: "Binding measured quantities for the major scalable trades beyond wet areas — one entry per work type present in scope: floor coverings by type and level (timber/carpet/tiles m2), new concrete slabs and paths (m2), retaining walls (lm x avg height), new decking (m2), new external cladding (m2), driveway (m2), scaffold/perimeter access (lm of scaffolded perimeter x number of lifts), new internal stairs (count), engineered footings/piers (count x depth per the engineering drawings), structural steel (member count or tonnes per the engineering drawings), sanitaryware/fixtures (count per the schedule). Measure from dimension chains and stated areas; omit work types not in scope",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[work quantity uom basis],
          properties: {
            work: { type: "string", description: "e.g. 'Timber flooring — upper level', 'Retaining walls', 'New slab — build-under'" },
            quantity: { type: "number" },
            uom: { type: "string" },
            basis: { type: "string", description: "Show the working: drawing/dimension source and the arithmetic" }
          }
        }
      },
      wet_area_takeoff: {
        type: "array",
        description: "One entry per wet area IN SCOPE, measured from the plan's stated room dimensions — this is the binding takeoff for tiling and waterproofing quantities",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[room floor_m2 wall_tile_m2 basis],
          properties: {
            room: { type: "string" },
            floor_m2: { type: "number", description: "NET floor area from internal face-to-face dimension chains — never overall (O/A) dimensions that include wall thicknesses" },
            wall_tile_m2: { type: "number", description: "Wall tiling area summed per elevation zone: only zones the internal elevations mark as tile (TIL codes), at their DIMENSIONED heights — dado/half-height walls at the drawn dado height, full-height only where drawn (typically shower/bath enclosures). Paint zones (PT codes) above a dado are not tile" },
            basis: { type: "string", description: "Show the working: drawing number(s) used, the internal dims taken, and each wall zone x height summed (e.g. 'DWG 514/520: floor 2.37x1.87=4.4; shower 2 walls 2.61m x 2.7 FH = 7.0; other walls 8.1m x 1.18 dado = 9.6')" }
          }
        }
      },
      window_count: { type: "integer" },
      external_door_count: { type: "integer" },
      roof_type: { type: "string" },
      external_cladding: { type: "string" },
      structural_notes: { type: "string", description: "Steel, engineered beams, retaining, slabs, footings" },
      site_notes: { type: "string", description: "Slope, access, demolition, asbestos likelihood (pre-1990 QLD homes), existing structures" },
      inclusions: { type: "array", items: { type: "string" }, description: "Notable items explicitly shown or specified" },
      exclusions: { type: "array", items: { type: "string" }, description: "Items explicitly excluded or clearly out of scope" },
      finish_level: { type: "string", enum: %w[basic standard high_end luxury],
                      description: "Finish level from the plans/brief: joinery extent, stone, glazing, fittings" },
      internal_lining_type: { type: "string", description: "plasterboard, VJ/tongue-and-groove, mixed — affects lining and painting rates" },
      external_repaint: { type: "boolean", description: "Whole external envelope painted/repainted (typical for weatherboard renovations)?" },
      glazing_notes: { type: "string", description: "Summary of the window/door schedule: counts, sizes, notable large/high-spec units, total glazed area if derivable" },
      internal_paint_area_m2: { type: "number", description: "Internal paint area (walls + ceilings) for surfaces IN SCOPE ONLY: new work plus rooms shown as renovated/relined. Exclude retained areas the plans leave untouched. Derive from the floor plans level by level" },
      external_paint_area_m2: { type: "number", description: "External paint area (cladding, eaves, trim) for surfaces in scope only; 0 if no external painting. Note whether the whole envelope or only new work is repainted" },
      duration_months: { type: "number", description: "Realistic construction duration in months, reasoned stage by stage: demolition/site prep, structure, lockup, services rough-in, linings, fitout, finishes, externals. Renovations of occupied-scale character homes run longer than new builds of the same area" },
      retained_scope_notes: { type: "string", description: "What the plans show as RETAINED and untouched (rooms, roof, cladding, structure) so those areas are not costed" },
      deck_patio_area_m2: { type: "number", description: "Total new deck/alfresco/patio area; 0 if none" },
      special_features: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[name detail],
          properties: {
            name: { type: "string", description: "e.g. in-ground pool, solar + battery, plantation shutters, lift, fireplace" },
            detail: { type: "string", description: "Size/extent/spec so it can be costed" }
          }
        },
        description: "Cost-significant features that need their own line items"
      }
    }
  }.freeze

  def initialize(estimate, client: Ai::Client.new, max_inline_bytes: MAX_INLINE_PDF_BYTES, verify: true)
    @estimate = estimate
    @client = client
    @max_inline_bytes = max_inline_bytes
    @verify = verify
  end

  # Two-pass: draft analysis, then an audit pass that re-reads the documents
  # against the draft with a checklist of the misses that cost real money.
  # The document blocks carry a cache breakpoint so the second read is cheap.
  def call
    blocks = plan_blocks
    draft = @client.complete_json(
      system: [ { type: "text", text: system_prompt } ],
      content: blocks + [ { type: "text", text: user_prompt } ],
      schema: SCHEMA
    )
    return draft unless @verify

    @client.complete_json(
      system: [ { type: "text", text: system_prompt } ],
      content: blocks + [ { type: "text", text: verification_prompt(draft) } ],
      schema: SCHEMA
    )
  end

  private

  def system_prompt
    <<~PROMPT
      You are an expert residential construction estimator in Queensland, Australia,
      analysing architectural plans for a builder. Extract the full scope of works,
      quantities, and anything that affects cost. Be precise about areas and counts —
      read the drawing schedules (window/door schedules, area calculations) where present.
      Where the plans don't state a figure, estimate it from the drawings and say so in your notes.
    PROMPT
  end

  def user_prompt
    parts = [ "Analyse the attached documents (architectural plans, and specification schedules or reports where provided) and produce the structured scope analysis. Specifications override drawings for finishes and fittings." ]
    parts << "COSTING SECTIONS available (choose relevant_sections from these exact names):\n#{template_section_names.join("; ")}"
    parts << "Additional information from the builder:\n#{@estimate.brief_text}" if @estimate.brief_text.present?
    parts.join("\n\n")
  end

  def verification_prompt(draft)
    <<~TEXT
      Below is a DRAFT scope analysis extracted from the attached documents. Audit it
      against the documents themselves and return the corrected analysis (same
      structure, complete). Check specifically:
      - Window/door schedule: exact counts, and which openings are NEW/REPLACED vs
        RETAINED (elevations and demolition plans show this)
      - Floor areas per level against stated areas or measurable dimensions
      - retained_scope_notes: everything the drawings keep (roof, cladding, rooms,
        structure) that the draft missed or wrongly costed as new
      - special_features completeness: pool, solar, shutters, skylights, fireplace,
        lifts, external structures - anything drawn or specified but absent from
        the draft
      - Paint areas consistent with the repaint extent in the builder brief and the
        retained scope
      - quantity_takeoff: re-derive every entry from dimension chains or stated
        areas; add entries for any major measurable trade in scope the draft
        missed (floor coverings, slabs, retaining, decking, cladding). An entry
        without dimension-level working in its basis is wrong
      - wet_area_takeoff: re-derive each room's figures from the drawings and
        REJECT any draft figure whose basis doesn't hold up. Floor areas from
        INTERNAL face-to-face dimension chains only — overall (O/A) dimensions
        include wall thicknesses and overstate small rooms badly. Wall tile per
        elevation zone at its dimensioned height: where the internal elevations
        dimension a tile dado with a paint code above it, the tile stops at the
        dado — full-height only where the elevations draw it (typically shower/
        bath enclosures). Where no height is documented, full-height to wet
        zones and 1200mm elsewhere. The basis field must show the working;
        an entry without dimension-level working is wrong
      - Raise/build-under jobs: check for new internal stairs connecting the
        levels (almost always present) and scaffold extent — both belong in
        quantity_takeoff
      - Builder-confirmed scope: every structural_work, systems_extras and
        external_works item the builder's clarifications state (pool, house raise,
        retaining walls, solar) must appear in scope_summary/special_features and
        be reflected in relevant_sections — the builder's stated scope is not
        optional
      - duration_months: staged reasoning (demo, structure, lockup, rough-in,
        linings, fitout, finishes, externals)
      - project_class and relevant_sections: correct for the actual scope; a
        partial job must not list whole-house sections
      - Anything in the builder brief contradicted by the documents: flag it in
        site_notes rather than silently overriding

      DRAFT ANALYSIS:
      #{JSON.pretty_generate(draft)}
    TEXT
  end

  def template_section_names
    template = @estimate.estimate_template || EstimateTemplate.for_user(@estimate.user)
    template ? template.section_names : []
  end

  # One document block per uploaded PDF, sharing an inline-base64 budget;
  # files that would blow the request size go via the Files API instead.
  # The last block gets a cache breakpoint so the verification pass re-reads
  # the documents from cache.
  def plan_blocks
    blocks = build_plan_blocks
    blocks.last[:cache_control] = { type: "ephemeral" } if blocks.any?
    blocks
  end

  def build_plan_blocks
    inline_budget = @max_inline_bytes
    @estimate.plans.map do |attachment|
      data = attachment.download
      pages = page_count(data)
      if pages && pages > MAX_PDF_PAGES
        raise Ai::Client::Error, "#{attachment.filename} has #{pages} pages — the maximum is #{MAX_PDF_PAGES}. Split it and upload the drawings only."
      end

      if data.bytesize <= inline_budget
        inline_budget -= data.bytesize
        { type: "document", source: { type: "base64", media_type: "application/pdf", data: Base64.strict_encode64(data) } }
      else
        file_id = @client.upload_pdf(data, filename: attachment.filename.to_s)
        { type: "document", source: { type: "file", file_id: file_id } }
      end
    end
  end

  # pdf-reader can't parse every real-world PDF (e.g. certified plan sets with
  # unusual xref structures); an unknown page count is fine — the API applies
  # its own limits and its parser is far more tolerant.
  def page_count(data)
    PDF::Reader.new(StringIO.new(data)).page_count
  rescue StandardError
    nil
  end
end
