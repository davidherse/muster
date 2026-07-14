# The clarifying-questions harness: after review, mine the estimate's own
# low-confidence assumptions for the questions a human estimator would ask
# before standing behind the number — inclusion boundaries, who-supplies,
# retained-vs-new, site unknowns. Ranked by dollar swing; answers bind and
# re-cost only the affected sections.
class QuestionHarvester
  SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[questions],
    properties: {
      questions: {
        type: "array",
        description: "Up to 8 questions, largest dollar swing first. Only questions whose answer would materially change the estimate — no questions the documents already answer.",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[question why sections swing_low swing_high],
          properties: {
            question: { type: "string", description: "One direct question the estimator would ask the client/builder, answerable in a sentence" },
            why: { type: "string", description: "Which assumption this replaces and what was assumed" },
            sections: { type: "array", items: { type: "string" }, description: "Exact section names whose line items the answer would change" },
            swing_low: { type: "number", description: "AUD ex GST: estimate total if the answer lands cheap" },
            swing_high: { type: "number", description: "AUD ex GST: estimate total impact if the answer lands expensive" }
          }
        }
      }
    }
  }.freeze

  def initialize(estimate, client: Ai::Client.new)
    @estimate = estimate
    @client = client
  end

  def call
    result = @client.complete_json(
      system: [ { type: "text", text: instructions } ],
      content: [ { type: "text", text: evidence_text } ],
      schema: SCHEMA
    )
    questions = Array(result["questions"]).first(8).each_with_index.map do |q, i|
      q.slice("question", "why", "sections", "swing_low", "swing_high").merge("id" => i + 1)
    end
    @estimate.update!(open_questions: questions)
    questions
  end

  private

  def instructions
    <<~PROMPT
      You are the estimator reviewing your own draft before sending a ballpark
      to a client. List the clarifying questions you would ask FIRST — the
      unknowns that swing this estimate most. Good questions target:
      - inclusion boundaries (prefab vs built on site; supply by owner vs
        builder; existing item retained vs replaced)
      - scope ambiguities the plans do not resolve (extent of rework to
        retained fabric, service upgrade extents, site access)
      - selections that move allowances (appliance level, fixture level)
      Never ask what the documents or the builder's brief already answer.
      Rank by dollar swing. Phrase each so a homeowner or site supervisor
      could answer it in one sentence.
    PROMPT
  end

  def evidence_text
    lines = @estimate.sections.order(:position).map do |section|
      items = section.line_items.map do |i|
        flag = i.confidence == "low" ? " [LOW CONFIDENCE]" : ""
        assumption = i.assumptions.present? ? " — assumed: #{i.assumptions}" : ""
        "  - #{i.description} | #{i.quantity} #{i.uom} | $#{i.total}#{flag}#{assumption}"
      end
      "#{section.name} ($#{section.subtotal}):\n#{items.join("\n")}"
    end
    <<~TEXT
      BUILDER'S BRIEF:
      #{@estimate.prompt}

      QUESTIONNAIRE ANSWERS (already known — do not re-ask):
      #{@estimate.questionnaire.to_h.map { |k, v| "  #{k}: #{Array(v).join(', ')}" }.join("\n")}

      #{@estimate.clarifications.present? ? "ALREADY CLARIFIED (do not re-ask):\n#{Array(@estimate.clarifications).map { |c| "  Q: #{c['question']} A: #{c['answer']}" }.join("\n")}\n" : ''}
      THE DRAFT ESTIMATE (total $#{@estimate.line_items.sum { |i| i.total.to_f }.round}):
      #{lines.join("\n\n")}
    TEXT
  end
end
