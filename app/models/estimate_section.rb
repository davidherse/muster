class EstimateSection < ApplicationRecord
  belongs_to :estimate
  has_many :line_items, -> { order(:position) }, class_name: "EstimateLineItem", dependent: :destroy

  validates :name, :position, presence: true

  def subtotal
    line_items.sum { |i| i.total || 0 }
  end

  def subtotal_low
    line_items.sum(&:range_low)
  end

  def subtotal_high
    line_items.sum(&:range_high)
  end
end
