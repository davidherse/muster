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
    required: %w[building_type storeys floor_area_m2 scope_summary rooms wet_area_count
                 window_count external_door_count roof_type external_cladding
                 structural_notes site_notes inclusions exclusions],
    properties: {
      building_type: { type: "string", description: "e.g. New double storey dwelling, Renovation and extension of existing Queenslander" },
      storeys: { type: "integer" },
      floor_area_m2: { type: "number", description: "Total floor area of works in square metres; estimate from plans if not stated" },
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
      window_count: { type: "integer" },
      external_door_count: { type: "integer" },
      roof_type: { type: "string" },
      external_cladding: { type: "string" },
      structural_notes: { type: "string", description: "Steel, engineered beams, retaining, slabs, footings" },
      site_notes: { type: "string", description: "Slope, access, demolition, asbestos likelihood (pre-1990 QLD homes), existing structures" },
      inclusions: { type: "array", items: { type: "string" }, description: "Notable items explicitly shown or specified" },
      exclusions: { type: "array", items: { type: "string" }, description: "Items explicitly excluded or clearly out of scope" }
    }
  }.freeze

  def initialize(estimate, client: Ai::Client.new, max_inline_bytes: MAX_INLINE_PDF_BYTES)
    @estimate = estimate
    @client = client
    @max_inline_bytes = max_inline_bytes
  end

  def call
    @client.complete_json(
      system: [ { type: "text", text: system_prompt } ],
      content: [ plan_block, { type: "text", text: user_prompt } ],
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
    parts = [ "Analyse the attached architectural plans and produce the structured scope analysis." ]
    parts << "Additional information from the builder:\n#{@estimate.prompt}" if @estimate.prompt.present?
    parts.join("\n\n")
  end

  def plan_block
    data = @estimate.plan.download
    pages = page_count(data)
    if pages && pages > MAX_PDF_PAGES
      raise Ai::Client::Error, "The plan PDF has #{pages} pages — the maximum is #{MAX_PDF_PAGES}. Split it and upload the drawings only."
    end

    if data.bytesize <= @max_inline_bytes
      { type: "document", source: { type: "base64", media_type: "application/pdf", data: Base64.strict_encode64(data) } }
    else
      # Too large to inline — upload via the Files API and reference by id.
      file_id = @client.upload_pdf(data, filename: @estimate.plan.filename.to_s)
      { type: "document", source: { type: "file", file_id: file_id } }
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
