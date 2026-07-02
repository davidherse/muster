class EstimateTemplate < ApplicationRecord
  has_many :estimates, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :sections, presence: true

  # sections is an ordered array of {"name" => ..., "hint" => ...} hashes
  def section_names
    sections.map { |s| s["name"] }
  end

  def self.default
    order(:id).first
  end
end
