class EstimateTemplate < ApplicationRecord
  belongs_to :user, optional: true
  has_many :estimates, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :sections, presence: true

  STATUSES = %w[proposed active].freeze
  validates :status, inclusion: { in: STATUSES }

  scope :global, -> { where(user_id: nil) }
  scope :active, -> { where(status: "active") }
  scope :proposed, -> { where(status: "proposed") }

  # sections is an ordered array of {"name" => ..., "hint" => ...} hashes.
  # Synthesized personal templates also carry "typical_items" => [...] per
  # section — the line items this builder usually breaks the section into.
  def section_names
    sections.map { |s| s["name"] }
  end

  def personal?
    user_id.present?
  end

  # Agreeing a proposal makes it the user's template; any previous personal
  # template is superseded.
  def activate!
    transaction do
      self.class.where(user: user).where.not(id: id).destroy_all if personal?
      update!(status: "active")
    end
  end

  # The shared starting template for users with no agreed personal template.
  def self.default
    global.active.order(:id).first
  end

  # The template a user's estimates should be built on: their agreed personal
  # template, else the shared default.
  def self.for_user(user)
    return default unless user
    active.where(user: user).order(updated_at: :desc).first || default
  end
end
