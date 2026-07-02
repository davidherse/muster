# Stands in for Ai::Client in tests. Returns a canned plan analysis or canned
# line item sections depending on which schema the caller passes.
class FakeAiClient
  attr_reader :calls, :uploads

  # fail_with: raise this error on every call; fail_after: succeed for N
  # complete_json calls, then raise fail_with on subsequent calls.
  def initialize(analysis: nil, fail_with: nil, fail_after: nil)
    @analysis = analysis
    @fail_with = fail_with
    @fail_after = fail_after
    @calls = []
    @uploads = []
  end

  def upload_pdf(data, filename: "plan.pdf")
    @uploads << { bytes: data.bytesize, filename: filename }
    "file_fake_#{@uploads.size}"
  end

  def complete_json(system:, content:, schema:, max_tokens: nil)
    @calls << { system: system, content: content, schema: schema }
    raise @fail_with if @fail_with && (@fail_after.nil? || @calls.size > @fail_after)

    if schema == PlanAnalyzer::SCHEMA
      @analysis || default_analysis
    else
      sections_response(content)
    end
  end

  private

  def default_analysis
    {
      "building_type" => "Renovation and extension",
      "storeys" => 2,
      "floor_area_m2" => 210.0,
      "scope_summary" => "Full renovation of existing dwelling with rear extension.",
      "rooms" => [ { "name" => "Kitchen", "level" => "Ground", "notes" => "New joinery" } ],
      "wet_area_count" => 2,
      "window_count" => 14,
      "external_door_count" => 3,
      "roof_type" => "Metal sheet",
      "external_cladding" => "Weatherboard",
      "structural_notes" => "Two steel beams to openings",
      "site_notes" => "Sloping block",
      "inclusions" => [ "New kitchen" ],
      "exclusions" => [ "Pool" ]
    }
  end

  # Echo back every requested section with two line items each,
  # marking any section containing "Solar" as not applicable.
  def sections_response(content)
    text = content.map { |b| b[:text] || b["text"] }.compact.join("\n")
    names = text.scan(/^- (.+?):/).flatten
    {
      "sections" => names.map do |name|
        if name.include?("Solar")
          { "name" => name, "applicable" => false, "line_items" => [] }
        else
          {
            "name" => name,
            "applicable" => true,
            "line_items" => [
              { "description" => "#{name} materials", "item_type" => "Mat", "uom" => "ea",
                "quantity" => 2, "unit_cost" => 100.0, "confidence" => "high", "assumptions" => "" },
              { "description" => "#{name} labour", "item_type" => "Lab", "uom" => "hour",
                "quantity" => 10, "unit_cost" => 70.0, "confidence" => "low", "assumptions" => "Assumed 10 hours" }
            ]
          }
        end
      end
    }
  end
end
