class EstimateLineItem < ApplicationRecord
  ITEM_TYPES = %w[Mat Lab Sub Eq MatLab].freeze
  CONFIDENCES = %w[high medium low].freeze

  # How far actual costs are expected to swing around the point estimate,
  # based on how confident the AI was in the quantity/rate.
  RANGE_FACTORS = {
    "high"   => 0.10,
    "medium" => 0.20,
    "low"    => 0.35
  }.freeze

  belongs_to :estimate_section
  has_one :estimate, through: :estimate_section

  validates :description, :position, presence: true
  validates :item_type, inclusion: { in: ITEM_TYPES }, allow_blank: true
  validates :confidence, inclusion: { in: CONFIDENCES }, allow_blank: true

  before_save :compute_total

  def range_factor
    RANGE_FACTORS.fetch(confidence, RANGE_FACTORS["medium"])
  end

  def range_low
    ((total || 0) * (1 - range_factor)).round(2)
  end

  def range_high
    ((total || 0) * (1 + range_factor)).round(2)
  end

  private

  def compute_total
    self.total = ((quantity || 0) * (unit_cost || 0)).round(2) if total.blank?
  end
end
