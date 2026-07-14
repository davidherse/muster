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

  # review_response can be overridden to test the reviewer's apply logic
  attr_accessor :review_response

  def complete_json(system:, content:, schema:, max_tokens: nil)
    @calls << { system: system, content: content, schema: schema }
    raise @fail_with if @fail_with && (@fail_after.nil? || @calls.size > @fail_after)

    if schema == PlanAnalyzer::SCHEMA
      @analysis || default_analysis
    elsif schema == TrainingIngestor::SCHEMA
      {
        "project_summary" => "Two storey renovation estimate.",
        "template_sections" => [ "Prelims", "Carpentry", "Wet Areas", "Painting" ],
        "items" => [
          { "category" => "Wet Areas", "description" => "Semi-frameless shower screen", "item_type" => "Mat", "uom" => "ea", "unit_cost" => 890.0, "quantity" => 2, "quantity_kind" => "measured" },
          { "category" => "Painting", "description" => "Internal repaint", "item_type" => "Sub", "uom" => "m2", "unit_cost" => 38.0, "quantity" => 120, "quantity_kind" => "measured" },
          { "category" => "Prelims", "description" => "Zero cost note", "item_type" => "Mat", "uom" => "ea", "unit_cost" => 0, "quantity" => 1, "quantity_kind" => "lump" }
        ]
      }
    elsif schema == QuestionHarvester::SCHEMA
      { "questions" => [
        { "question" => "Are the appliances owner-supplied or builder-supplied?",
          "why" => "Assumed builder-supplied at standard allowance",
          "sections" => [ "Wet Areas" ], "swing_low" => -8000, "swing_high" => 0 }
      ] }
    elsif schema == TemplateSynthesizer::SCHEMA
      {
        "template_name" => "Renovation template",
        "sections" => [
          { "name" => "Prelims", "hint" => "Site setup and supervision", "typical_items" => [ "Supervision (Hour)" ] },
          { "name" => "Carpentry", "hint" => "Framing and fixout", "typical_items" => [] },
          { "name" => "Wet Areas", "hint" => "Bathroom and laundry fitout", "typical_items" => [ "Semi-frameless shower screen (ea)" ] },
          { "name" => "Painting", "hint" => "Internal and external painting", "typical_items" => [ "Internal repaint (m2)" ] }
        ]
      }
    elsif schema == EstimateAssessor::SCHEMA
      { "confidence" => "high", "expected_variance_pct" => 10.0,
        "rationale" => "Well documented.", "strengths" => [ "docs" ], "risks" => [ "none" ] }
    elsif schema == EstimateReviewer::SCHEMA
      # canned review applies once; subsequent passes see a sound estimate
      response = @review_response || { "review_notes" => "Sound.", "changes" => [] }
      @review_response = nil
      response
    else
      sections_response(content)
    end
  end

  private

  def default_analysis
    {
      "project_class" => "whole_house_renovation",
      "relevant_sections" => [],
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
