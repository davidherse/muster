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

  # Roll section totals up into the estimate's total and low/high range.
  def recalculate_totals!
    items = line_items.reload
    update!(
      total: items.sum { |i| i.total || 0 },
      total_low: items.sum { |i| i.range_low },
      total_high: items.sum { |i| i.range_high }
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
