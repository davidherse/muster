class PriceBookItem < ApplicationRecord
  SOURCE_KINDS = %w[base user market].freeze

  belongs_to :account, optional: true

  validates :category, :description, presence: true
  validates :unit_cost, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :account, presence: true, if: -> { source_kind == "user" }

  scope :ordered, -> { order(:category, :description) }
  scope :base, -> { where(source_kind: "base") }
  scope :market, -> { where(source_kind: "market") }
  scope :for_account, ->(account) { where(source_kind: "user", account: account) }
  # Entries a specific training document produced ("training:<id>", possibly
  # with an " | escalated ..." suffix — a bare prefix LIKE would also match
  # other doc ids sharing leading digits).
  scope :from_training_doc, ->(account, doc_id) {
    tag = "training:#{doc_id}"
    for_account(account).where("source = ? OR source LIKE ?", tag, "#{tag} %")
  }

  # Compact text listing used to ground the AI's pricing.
  def self.reference_text(scope: all, with_context: false)
    scope.ordered.map do |i|
      line = "#{i.category} | #{i.description} | #{i.item_type} | #{i.uom} | $#{i.unit_cost}"
      if with_context && i.context.present?
        ctx = i.context.map { |k, v| "#{k}: #{Array(v).join('/')}" }.join(", ")
        line += " | [#{ctx}]"
      end
      line
    end.join("\n")
  end
end
