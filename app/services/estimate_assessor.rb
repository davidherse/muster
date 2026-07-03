# Final self-assessment: how confident is the estimator in this number, and
# what variance should the builder expect? Grounded in observable signals
# (document quality, brief completeness, price book coverage, review
# corrections) — it never sees a target price. The stated variance drives the
# displayed range (floor of ±10%).
class EstimateAssessor
  MIN_VARIANCE_PCT = 10.0

  SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[confidence expected_variance_pct rationale strengths risks],
    properties: {
      confidence: { type: "string", enum: %w[high medium low],
                    description: "Overall confidence in the point estimate" },
      expected_variance_pct: { type: "number",
                               description: "Realistic +/- percentage band around the total (10-30 typical)" },
      rationale: { type: "string", description: "One or two sentences for the builder" },
      strengths: { type: "array", items: { type: "string" }, description: "What was well grounded" },
      risks: { type: "array", items: { type: "string" }, description: "What could move the price most" }
    }
  }.freeze

  def initialize(estimate, analysis:, review_notes:, client: Ai::Client.new)
    @estimate = estimate
    @analysis = analysis
    @review_notes = review_notes
    @client = client
  end

  def call
    result = @client.complete_json(
      system: [ { type: "text", text: instructions } ],
      content: [ { type: "text", text: request_text } ],
      schema: SCHEMA,
      max_tokens: 4_000
    )
    result["expected_variance_pct"] = result["expected_variance_pct"].to_f.clamp(MIN_VARIANCE_PCT, 35.0)
    @estimate.update!(assessment: result)
    result
  end

  private

  def instructions
    <<~PROMPT
      You are a senior estimator assessing how much trust to place in an estimate
      your team has just produced. You do not know the "right" price — judge only
      from the signals: how complete and legible the documents were, how much of
      the brief/questionnaire was answered, how unusual the project is, how much
      the review passes had to correct, and how much of the pricing could be
      grounded in the builder's own price book versus market judgement. Typical
      plan-based estimates on well-documented conventional jobs land within
      +/-10%; unusual, character-heavy, or thinly documented jobs realistically
      carry +/-15-25%. Be honest, not reassuring.
    PROMPT
  end

  def request_text
    q = @estimate.questionnaire || {}
    answered = q.values.count(&:present?)
    <<~TEXT
      PROJECT: #{@analysis["project_class"]}, #{@analysis["building_type"]}
      Floor area: #{@analysis["floor_area_m2"]} m2; duration est: #{@analysis["duration_months"]} months
      Documents supplied: #{@estimate.plans.map { |p| p.filename.to_s }.join(", ")}
      Questionnaire: #{answered} of #{EstimateQuestionnaire::QUESTIONS.size} answered
      Brief: #{@estimate.brief_text.to_s.truncate(600)}

      ESTIMATE SHAPE:
      Total: $#{@estimate.line_items.sum { |i| i.total.to_f }.round}
      Sections: #{@estimate.sections.count}; line items: #{@estimate.line_items.count}
      Low-confidence line items: #{@estimate.line_items.where(confidence: "low").count}
      Analysis site notes: #{@analysis["site_notes"].to_s.truncate(300)}

      REVIEW FINDINGS (what the audit passes changed):
      #{@review_notes.to_s.truncate(900)}
    TEXT
  end
end
