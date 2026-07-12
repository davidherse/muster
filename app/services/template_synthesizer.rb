# Merges everything learned from a user's training uploads into ONE proposed
# personal estimate template: the sections they use, in their order, with the
# line items they typically break each section into. Structure only — no
# prices. The user reviews and agrees the proposal in onboarding; agreeing
# makes it the template their estimates are built on.
class TemplateSynthesizer
  SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[template_name sections],
    properties: {
      template_name: { type: "string", description: "Short human name for this builder's estimate style, e.g. 'Trade-sequenced renovation template'" },
      sections: {
        type: "array",
        description: "The merged template sections in this builder's preferred order",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[name hint typical_items],
          properties: {
            name: { type: "string", description: "Section name exactly as this builder writes it (generalise only job-specific wording)" },
            hint: { type: "string", description: "One line: what belongs in this section for this builder" },
            typical_items: {
              type: "array", items: { type: "string" },
              description: "Line items this builder recurringly carries in this section, phrased their way, with unit of measure where they use one — e.g. 'Plasterboard supply & fix (m2)'. No prices."
            }
          }
        }
      }
    }
  }.freeze

  def initialize(user, client: Ai::Client.new)
    @user = user
    @client = client
  end

  # Returns the proposed EstimateTemplate, or nil when there is nothing to
  # learn from yet.
  def call
    docs = @user.training_documents.where(status: "completed").select { |d| d.extraction.present? }
    return nil if docs.empty?

    result = @client.complete_json(
      system: [ { type: "text", text: instructions } ],
      content: [ { type: "text", text: evidence_text(docs) } ],
      schema: SCHEMA
    )
    sections = Array(result["sections"]).select { |s| s["name"].present? }
    return nil if sections.size < 3

    upsert_proposal(result["template_name"], sections)
  end

  private

  def instructions
    <<~PROMPT
      You are deriving a builder's personal estimate template from their own
      past estimate documents. Every builder structures estimates differently:
      section names, section order, and how finely work is broken into line
      items. Your job is to capture THIS builder's conventions so future
      estimates read like they wrote them.

      Rules:
      - Merge the documents into one reusable template. Where documents agree,
        keep names and ordering verbatim. Where they differ, prefer the
        majority convention, then the most recent document.
      - Generalise job-specific wording ("Demolish rear lean-to" becomes a
        typical item like "Demolition of existing structures") but keep the
        builder's vocabulary and level of granularity — if they itemise
        fixings and sealants, the template says so; if they carry one lump
        per trade, the template says that.
      - typical_items are the recurring line items per section with unit of
        measure where the builder uses one. Structure only — never include
        prices or rates.
      - Include every section any document uses that would recur on future
        jobs (preliminaries, margin, supervision included). Drop one-off
        oddities.
    PROMPT
  end

  def evidence_text(docs)
    parts = docs.sort_by(&:created_at).map do |doc|
      ex = doc.extraction
      items = PriceBookItem.from_training_doc(@user, doc.id)
      sample = items.group_by(&:category).map do |cat, entries|
        lines = entries.first(10).map { |i| "    - #{i.description} (#{i.uom})" }
        "  #{cat}:\n#{lines.join("\n")}"
      end
      <<~DOC
        DOCUMENT: #{doc.name} (uploaded #{doc.created_at.to_date})
        Summary: #{ex['project_summary']}
        Sections in document order: #{Array(ex['template_sections']).join(' | ')}
        Line items by section (sample):
        #{sample.join("\n")}
      DOC
    end
    "#{parts.join("\n")}\nDerive this builder's single personal estimate template."
  end

  def upsert_proposal(name, sections)
    template = EstimateTemplate.find_or_initialize_by(user: @user, status: "proposed")
    template.update!(
      name: unique_name(template, name),
      description: "Personal template derived from #{@user.training_documents.where(status: 'completed').count} uploaded estimate(s). Review and agree to use it for your estimates.",
      sections: sections
    )
    template
  end

  # Template names are globally unique; scope the synthesized name per user.
  def unique_name(template, proposed)
    base = "#{@user.name} — #{proposed.presence || 'Personal template'}".truncate(120)
    return base unless EstimateTemplate.where(name: base).where.not(id: template.id).exists?
    "#{base} (#{@user.id})"
  end
end
