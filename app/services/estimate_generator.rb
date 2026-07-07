# Orchestrates the full estimate pipeline: plan analysis, batched line item
# generation, and totals. Called from GenerateEstimateJob.
#
# Completed batches are tracked in estimate.costed_sections, so a run that
# dies mid-way (e.g. rate limits exhausted) can resume without re-paying for
# the plan analysis or already-costed sections.
class EstimateGenerator
  BATCH_SIZE = ENV.fetch("ESTIMATOR_BATCH_SIZE", 6).to_i

  def initialize(estimate, client: nil, batch_size: BATCH_SIZE)
    @estimate = estimate
    @client = client || default_client
    @batch_size = batch_size
  end

  def call(resume: false)
    resume &&= @estimate.plan_summary.present?

    analysis =
      if resume
        @estimate.update!(status: "processing", error_message: nil, progress_note: "Resuming…")
        @estimate.plan_summary
      else
        fresh_analysis
      end

    generator = LineItemGenerator.new(@estimate, analysis: analysis, client: @client)
    all_sections = applicable_sections(analysis)
    remaining = all_sections.reject { |s| @estimate.costed_sections.include?(s["name"]) }
    done = all_sections.size - remaining.size
    position = @estimate.sections.maximum(:position) || 0

    remaining.each_slice(@batch_size) do |batch|
      result = generator.call(batch)
      # One transaction per batch: section rows and the costed_sections marker
      # commit together, so a mid-batch crash can't duplicate work on resume.
      ActiveRecord::Base.transaction do
        result.fetch("sections", []).each do |section_data|
          section_data["name"] = normalize_section_name(section_data["name"], batch)
          next unless section_data["applicable"] && section_data["line_items"].present?
          position += 1
          create_section(section_data, position)
        end
        @estimate.update!(costed_sections: @estimate.costed_sections + batch.map { |s| s["name"] })
      end
      done += batch.size
      percent = 20 + (70.0 * done / all_sections.size).round
      @estimate.update_progress!(percent, "Costed #{done} of #{all_sections.size} sections…")
    end

    @estimate.update_progress!(92, "Reviewing the estimate…")
    review = EstimateReviewer.new(@estimate, analysis: analysis, client: @client).call
    # Stored for auditability: which passes ran, what they added/removed,
    # and what the generation cost.
    usage = @client.respond_to?(:usage_totals) ? @client.usage_totals : nil
    @estimate.update!(assessment: review.merge(usage: usage))

    @estimate.recalculate_totals!
    @estimate.update!(status: "completed", progress: 100, progress_note: nil)
  rescue StandardError => e
    @estimate.fail!(friendly_message(e))
    raise
  end

  private

  # Surfaces retry waits on the progress page while the client backs off.
  def default_client
    Ai::Client.new(on_retry: lambda { |error, attempt, delay|
      reason = error.is_a?(Anthropic::Errors::RateLimitError) ? "Rate limited" : "AI service busy"
      @estimate.update_progress!(@estimate.progress, "#{reason} — retrying in #{delay}s (attempt #{attempt + 1})…")
    })
  end

  def fresh_analysis
    @estimate.processing!("Analysing plans…")
    @estimate.update!(costed_sections: [])
    @estimate.sections.destroy_all

    analysis = PlanAnalyzer.new(@estimate, client: @client).call
    @estimate.update!(
      plan_summary: analysis,
      building_type: analysis["building_type"],
      floor_area: analysis["floor_area_m2"].to_s
    )
    @estimate.update_progress!(20, "Plans analysed. Costing sections…")
    analysis
  end

  def template
    @estimate.estimate_template || EstimateTemplate.default ||
      raise(Ai::Client::Error, "No estimate template available")
  end

  # For partial/small jobs the analysis nominates which sections exist at all;
  # whole-house classes always cost the full template (dropping scope is the
  # worse failure there). Preliminaries and cleaning always stay.
  ALWAYS_SECTIONS = [ "Preliminaries", "Site Cleaning and Waste Removal", "Internal Cleaning" ].freeze
  PARTIAL_CLASSES = %w[partial_interior_renovation small_works].freeze

  def applicable_sections(analysis)
    sections = template.sections
    return sections unless PARTIAL_CLASSES.include?(analysis["project_class"])

    relevant = Array(analysis["relevant_sections"])
    return sections if relevant.empty?

    kept = sections.select { |s| relevant.include?(s["name"]) || ALWAYS_SECTIONS.include?(s["name"]) }
    kept.presence || sections
  end

  # The model occasionally echoes the section hint ("Painting: Internal and
  # external…"); collapse back to the exact template name when it matches.
  def normalize_section_name(name, batch)
    return name if batch.any? { |s| s["name"] == name }
    prefix = name.to_s.split(":").first.to_s.strip
    batch.any? { |s| s["name"] == prefix } ? prefix : name
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
    when Anthropic::Errors::BadRequestError
      api_message = error.message.to_s[/message"?\s*[:=>]+\s*"([^"]+)"/, 1] || error.message.to_s.truncate(300)
      "The AI service rejected the request: #{api_message}"
    when Anthropic::Errors::RateLimitError
      "The AI service is rate limited right now. Retries were exhausted — try again in a few minutes."
    when Anthropic::Errors::APIStatusError
      "The AI service returned an error (#{error.status}). Please try again."
    when Anthropic::Errors::APIConnectionError
      "Could not reach the AI service. Check your connection and try again."
    else
      "Something went wrong while generating the estimate: #{error.message.to_s.truncate(200)}"
    end
  end
end
