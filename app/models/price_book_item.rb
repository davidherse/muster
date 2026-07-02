class PriceBookItem < ApplicationRecord
  validates :category, :description, presence: true
  validates :unit_cost, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :ordered, -> { order(:category, :description) }

  # Compact text listing used to ground the AI's pricing.
  def self.reference_text(categories: nil)
    scope = ordered
    scope = scope.where(category: categories) if categories.present?
    scope.map { |i| "#{i.category} | #{i.description} | #{i.item_type} | #{i.uom} | $#{i.unit_cost}" }.join("\n")
  end
end
