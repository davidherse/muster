class Estimate < ApplicationRecord
  STATUSES = %w[draft processing completed failed].freeze

  belongs_to :user, optional: true
  belongs_to :account
  before_validation { self.account ||= user&.account }
  belongs_to :estimate_template, optional: true
  has_many :sections, -> { order(:position) }, class_name: "EstimateSection", dependent: :destroy
  has_many :line_items, through: :sections
  has_many_attached :plans

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :plans_must_be_pdfs

  scope :recent_first, -> { order(created_at: :desc) }

  STATUSES.each do |s|
    define_method("#{s}?") { status == s }
  end

  # A generation run heartbeats claimed_at while it works; a claim older
  # than this is treated as abandoned (the worker died) and may be taken over.
  CLAIM_STALE_AFTER = 15.minutes

  def claim_live?
    claimed_at.present? && claimed_at > CLAIM_STALE_AFTER.ago
  end

  # Processing, but neither claimed recently nor touched recently — the run
  # died or was never picked up. The UI offers "Try again" in this state.
  def generation_stalled?
    processing? && (claimed_at || updated_at) <= CLAIM_STALE_AFTER.ago
  end

  # Completed but gated behind unanswered clarifying questions — the user's
  # move, and the UI should say so.
  def needs_answers?
    completed? && Array(open_questions).any? { |q| !q["skipped"] }
  end

  # The full brief the AI works from: free-text prompt plus questionnaire answers.
  def brief_text
    [ prompt.presence, EstimateQuestionnaire.to_prompt(questionnaire) ].compact.join("\n\n").presence
  end

  def processing!(note = nil)
    update!(status: "processing", error_message: nil, progress: 0, progress_note: note)
  end

  def fail!(message)
    update!(status: "failed", error_message: message.to_s.truncate(2000))
  end

  def update_progress!(percent, note)
    update!(progress: percent, progress_note: note)
  end

  # Roll section totals into the estimate total; the headline range is a flat
  # ±10% band reflecting measured whole-of-estimate accuracy.
  RANGE_PCT = 0.10

  def recalculate_totals!
    items = line_items.reload
    sum = items.sum { |i| i.total || 0 }
    update!(
      total: sum,
      total_low: (sum * (1 - RANGE_PCT)).round(2),
      total_high: (sum * (1 + RANGE_PCT)).round(2)
    )
  end

  OVERRIDE_PREFIX = /\ABUILDER-CONFIRMED PROJECT TYPE: [^.]*\. /

  # Builder-stated facts BIND over analyzer inference: the builder knows the
  # job type, and a stated works area pins the composite multiplier. Safe to
  # apply more than once — the recorded conflict note is replaced, not stacked.
  def apply_questionnaire_overrides(analysis)
    q = questionnaire.to_h
    if (klass = EstimateQuestionnaire::PROJECT_TYPES[q["project_type"]])
      base = analysis["scope_summary"].to_s.sub(OVERRIDE_PREFIX, "")
      original = analysis["original_project_class"] || analysis["project_class"]
      if original != klass
        analysis["original_project_class"] = original
        analysis["scope_summary"] = "BUILDER-CONFIRMED PROJECT TYPE: #{klass} (plans read as #{original}). " + base
        analysis["project_class"] = klass
      end
    elsif analysis["original_project_class"].present?
      analysis["project_class"] = analysis["original_project_class"]
      analysis["scope_summary"] = analysis["scope_summary"].to_s.sub(OVERRIDE_PREFIX, "")
      analysis.delete("original_project_class")
    end
    area = q["works_floor_area_m2"].to_f
    analysis["floor_area_m2"] = area if area.positive?
    analysis
  end

  # Re-apply the overrides to the stored analysis (after the questionnaire
  # changed) — no AI call. Returns false when there is no analysis or
  # nothing changed.
  def reapply_questionnaire_overrides!
    return false if plan_summary.blank?
    analysis = apply_questionnaire_overrides(plan_summary.deep_dup)
    return false if analysis == plan_summary
    update!(plan_summary: analysis, floor_area: analysis["floor_area_m2"].to_s)
    true
  end

  def template_section_names
    (estimate_template || EstimateTemplate.for_account(account))&.section_names || []
  end

  # Schedule sections for re-costing on the next resume run: drop their rows
  # and markers so the generator treats them as uncosted. Returns the names
  # actually scheduled (unknown names are ignored).
  def recost!(section_names)
    names = Array(section_names).map(&:to_s) & template_section_names
    return [] if names.empty?
    transaction do
      sections.where(name: names).destroy_all
      update!(costed_sections: costed_sections - names, status: "processing", error_message: nil, progress: 0,
        progress_note: "Re-costing #{names.size} #{'section'.pluralize(names.size)}…")
    end
    names
  end

  private

  def plans_must_be_pdfs
    plans.each do |attachment|
      errors.add(:plans, "must all be PDFs") unless attachment.content_type == "application/pdf"
      errors.add(:plans, "files must each be smaller than 50 MB") if attachment.byte_size > 50.megabytes
    end
  end
end
