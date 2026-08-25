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
    claim!(resume)

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

    # The clarifying-questions harness: what would the estimator ask before
    # standing behind this number? One round only — an estimate the user has
    # already clarified or skipped through finishes clean rather than
    # re-gating forever. Failure here must not fail the estimate.
    if @estimate.clarifications.blank? && Array(@estimate.open_questions).empty?
      begin
        QuestionHarvester.new(@estimate, client: @client).call
      rescue StandardError => e
        Rails.logger.warn("QuestionHarvester failed for estimate #{@estimate.id}: #{e.message}")
      end
    end
  rescue StandardError => e
    @estimate.fail!(friendly_message(e))
    raise
  ensure
    release_claim
  end

  private

  # Surfaces retry waits on the progress page while the client backs off.
  def default_client
    Ai::Client.new(on_retry: lambda { |error, attempt, delay|
      reason = error.is_a?(Anthropic::Errors::RateLimitError) ? "Rate limited" : "AI service busy"
      @estimate.update_progress!(@estimate.progress, "#{reason} — retrying in #{delay}s (attempt #{attempt + 1})…")
    })
  end

  # Two generators racing one estimate duplicate its sections. A fresh run
  # claims the estimate inside a row lock and refuses if another run holds
  # the claim; resume (crash recovery) takes the claim over deliberately.
  # The claim is separate from status: the controller sets "processing"
  # before enqueuing so the UI shows progress immediately, and that must
  # not read as "someone else owns this".
  def claim!(resume)
    @estimate.with_lock do
      if !resume && @estimate.claimed_at.present?
        raise Ai::Client::Error, "This estimate is already being generated."
      end
      @estimate.update!(claimed_at: Time.current, status: "processing")
    end
    @claimed = true
  end

  # Only the run that holds the claim may release it — a refused run must
  # not free the claim of the run that refused it.
  def release_claim
    @estimate.update_column(:claimed_at, nil) if @claimed
  end

  def fresh_analysis
    @estimate.processing!("Analysing plans…")
    @estimate.update!(costed_sections: [])
    @estimate.sections.destroy_all

    analysis = PlanAnalyzer.new(@estimate, client: @client).call
    apply_questionnaire_overrides(analysis)
    @estimate.update!(
      plan_summary: analysis,
      building_type: analysis["building_type"],
      floor_area: analysis["floor_area_m2"].to_s
    )
    @estimate.update_progress!(20, "Plans analysed. Costing sections…")
    analysis
  end

  # Builder-stated facts BIND over analyzer inference: the builder knows the
  # job type (a misclassification flips review direction and rate binding),
  # and a stated works area pins the composite multiplier. Conflicts are
  # recorded, never silently swallowed.
  def apply_questionnaire_overrides(analysis)
    q = @estimate.questionnaire.to_h
    if (klass = EstimateQuestionnaire::PROJECT_TYPES[q["project_type"]])
      if analysis["project_class"] != klass
        analysis["scope_summary"] = "BUILDER-CONFIRMED PROJECT TYPE: #{klass} (plans read as #{analysis['project_class']}). " + analysis["scope_summary"].to_s
        analysis["project_class"] = klass
      end
    end
    area = q["works_floor_area_m2"].to_f
    if area.positive?
      analysis["floor_area_m2"] = area
    end
    analysis
  end

  def template
    @estimate.estimate_template || EstimateTemplate.for_user(@estimate.user) ||
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
    # The model occasionally emits the same section name under two template
    # slots in one run; merge rather than create a same-named sibling.
    section = @estimate.sections.find_by(name: section_data["name"]) ||
              @estimate.sections.create!(name: section_data["name"], position: position)
    base_position = section.line_items.maximum(:position) || 0
    items = section_data["line_items"].each_with_index.map do |item, idx|
      quantity = item["quantity"].to_d
      unit_cost = item["unit_cost"].to_d
      {
        estimate_section_id: section.id,
        position: base_position + idx + 1,
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
