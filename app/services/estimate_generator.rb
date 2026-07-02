# Orchestrates the full estimate pipeline: plan analysis, batched line item
# generation, and totals. Called from GenerateEstimateJob.
class EstimateGenerator
  BATCH_SIZE = 8

  def initialize(estimate, client: Ai::Client.new)
    @estimate = estimate
    @client = client
  end

  def call
    @estimate.processing!("Analysing plans…")

    analysis = PlanAnalyzer.new(@estimate, client: @client).call
    @estimate.update!(
      plan_summary: analysis,
      building_type: analysis["building_type"],
      floor_area: analysis["floor_area_m2"].to_s
    )
    @estimate.update_progress!(20, "Plans analysed. Costing sections…")

    @estimate.sections.destroy_all
    generator = LineItemGenerator.new(@estimate, analysis: analysis, client: @client)
    template_sections = template.sections
    batches = template_sections.each_slice(BATCH_SIZE).to_a

    position = 0
    batches.each_with_index do |batch, i|
      result = generator.call(batch)
      result.fetch("sections", []).each do |section_data|
        next unless section_data["applicable"] && section_data["line_items"].present?
        position += 1
        create_section(section_data, position)
      end
      percent = 20 + (70.0 * (i + 1) / batches.size).round
      @estimate.update_progress!(percent, "Costed #{[ (i + 1) * BATCH_SIZE, template_sections.size ].min} of #{template_sections.size} sections…")
    end

    @estimate.recalculate_totals!
    @estimate.update!(status: "completed", progress: 100, progress_note: nil)
  rescue StandardError => e
    @estimate.fail!(friendly_message(e))
    raise
  end

  private

  def template
    @estimate.estimate_template || EstimateTemplate.default ||
      raise(Ai::Client::Error, "No estimate template available")
  end

  def create_section(section_data, position)
    section = @estimate.sections.create!(name: section_data["name"], position: position)
    items = section_data["line_items"].each_with_index.map do |item, idx|
      quantity = item["quantity"].to_d
      unit_cost = item["unit_cost"].to_d
      {
        estimate_section_id: section.id,
        position: idx + 1,
        description: item["description"],
        item_type: EstimateLineItem::ITEM_TYPES.include?(item["item_type"]) ? item["item_type"] : nil,
        uom: item["uom"],
        quantity: quantity,
        unit_cost: unit_cost,
        total: (quantity * unit_cost).round(2),
        confidence: EstimateLineItem::CONFIDENCES.include?(item["confidence"]) ? item["confidence"] : "medium",
        assumptions: item["assumptions"].presence,
        created_at: Time.current,
        updated_at: Time.current
      }
    end
    EstimateLineItem.insert_all(items) if items.any?
  end

  def friendly_message(error)
    case error
    when Ai::Client::RefusalError, Ai::Client::TruncatedError, Ai::Client::Error
      error.message
    when Anthropic::Errors::AuthenticationError
      "The Anthropic API key is missing or invalid. Set ANTHROPIC_API_KEY and try again."
    when Anthropic::Errors::RateLimitError
      "The AI service is rate limited right now. Please try again in a few minutes."
    when Anthropic::Errors::APIStatusError
      "The AI service returned an error (#{error.status}). Please try again."
    when Anthropic::Errors::APIConnectionError
      "Could not reach the AI service. Check your connection and try again."
    else
      "Something went wrong while generating the estimate: #{error.message.to_s.truncate(200)}"
    end
  end
end
