# Stage 1 of estimate generation: read the architectural plan PDF and the
# user's brief, and produce a structured scope-of-works analysis that the
# line item generator works from (so the PDF is only sent to the model once).
class PlanAnalyzer
  # Base64 inflates ~4/3; stay under the 32 MB request limit with headroom.
  MAX_PDF_BYTES = 20.megabytes
  MAX_PDF_PAGES = 100

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

  def initialize(estimate, client: Ai::Client.new)
    @estimate = estimate
    @client = client
  end

  def call
    @client.complete_json(
      system: [ { type: "text", text: system_prompt } ],
      content: plan_blocks + [ { type: "text", text: user_prompt } ],
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

  def plan_blocks
    data = @estimate.plan.download
    if data.bytesize <= MAX_PDF_BYTES && page_count(data) <= MAX_PDF_PAGES
      [ { type: "document", source: { type: "base64", media_type: "application/pdf", data: Base64.strict_encode64(data) } } ]
    else
      # Too large to send as a document — fall back to extracted text.
      [ { type: "text", text: "Extracted text of the architectural plans (drawings unavailable):\n\n#{extract_text(data)}" } ]
    end
  end

  def page_count(data)
    PDF::Reader.new(StringIO.new(data)).page_count
  rescue StandardError
    MAX_PDF_PAGES + 1
  end

  def extract_text(data)
    reader = PDF::Reader.new(StringIO.new(data))
    reader.pages.map(&:text).join("\n\n").first(400_000)
  rescue StandardError => e
    raise Ai::Client::Error, "Could not read the PDF plan: #{e.message}"
  end
end
