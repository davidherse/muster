class Estimate < ApplicationRecord
  STATUSES = %w[draft processing completed failed].freeze

  belongs_to :user
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

  # Roll section totals into the estimate total; the headline range reflects
  # the assessed accuracy of the whole estimate (floor ±10%), not the sum of
  # per-item confidence bands (which over-widen).
  def recalculate_totals!
    items = line_items.reload
    sum = items.sum { |i| i.total || 0 }
    variance = (assessment["expected_variance_pct"].presence || 10.0).to_f.clamp(10.0, 35.0) / 100.0
    update!(
      total: sum,
      total_low: (sum * (1 - variance)).round(2),
      total_high: (sum * (1 + variance)).round(2)
    )
  end

  private

  def plans_must_be_pdfs
    plans.each do |attachment|
      errors.add(:plans, "must all be PDFs") unless attachment.content_type == "application/pdf"
      errors.add(:plans, "files must each be smaller than 50 MB") if attachment.byte_size > 50.megabytes
    end
  end
end
