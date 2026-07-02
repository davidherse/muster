# Final pass of estimate generation: reviews the assembled estimate against
# the scope analysis the way a senior estimator checks a takeoff — flagging
# sections that are thin OR padded relative to the documented scope, and
# correcting them with explicit line item changes. Symmetric by design: it is
# told to look for both under- and over-estimation.
class EstimateReviewer
  SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[review_notes changes],
    properties: {
      review_notes: { type: "string", description: "Brief summary of what the review found" },
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

  def call
    result = @client.complete_json(
      system: [ { type: "text", text: instructions } ],
      content: [ { type: "text", text: request_text } ],
      schema: SCHEMA
    )
    apply(result)
    result["review_notes"]
  end

  private

  def instructions
    <<~PROMPT
      You are a senior residential construction estimator in Queensland, Australia,
      reviewing a completed estimate prepared from the attached scope analysis.
      Check it the way you would check a junior's takeoff, in both directions:

      - MISSING or THIN scope: features in the analysis or brief with no line items,
        quantities inconsistent with the documented areas/counts (e.g. paint priced
        well below the stated paint area, fewer window openings than the schedule),
        durations not carried through hire/preliminaries.
      - PADDED or DOUBLE-COUNTED scope: items for work the plans show as retained,
        the same work costed in two sections, quantities exceeding the documented
        geometry, or trades upgraded beyond the specified finish level.

      Only correct what you can justify from the analysis and brief. If a section is
      sound, leave it alone — an empty changes list is a good outcome. Keep unit
      rates consistent with the rates already used elsewhere in the estimate.
      All amounts AUD ex. GST, builder's costs.
    PROMPT
  end

  def request_text
    <<~TEXT
      SCOPE ANALYSIS:
      #{JSON.pretty_generate(@analysis)}

      #{@estimate.prompt.present? ? "BUILDER'S BRIEF:\n#{@estimate.prompt}\n" : ''}
      THE ESTIMATE TO REVIEW:
      #{estimate_text}
    TEXT
  end

  def estimate_text
    @estimate.sections.includes(:line_items).map do |section|
      items = section.line_items.map do |i|
        "  - #{i.description} | #{i.item_type} | #{i.quantity&.to_f} #{i.uom} @ $#{i.unit_cost&.to_f} = $#{i.total&.to_f} (#{i.confidence})"
      end
      "#{section.name} — subtotal $#{section.subtotal.to_f.round}\n#{items.join("\n")}"
    end.join("\n\n")
  end

  def apply(result)
    result.fetch("changes", []).each do |change|
      section = @estimate.sections.find_by(name: change["section"]) ||
                @estimate.sections.create!(name: change["section"],
                                           position: (@estimate.sections.maximum(:position) || 0) + 1)

      change.fetch("remove_descriptions", []).each do |desc|
        section.line_items.where(description: desc).destroy_all
      end

      next_position = (section.line_items.maximum(:position) || 0)
      change.fetch("add_items", []).each do |item|
        next_position += 1
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
  end
end
