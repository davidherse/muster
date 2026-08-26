class EstimateTemplate < ApplicationRecord
  belongs_to :user, optional: true
  has_many :estimates, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :sections, presence: true
  validate :sections_must_be_named

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

  # The user's agreed personal template, if any.
  def self.personal_for(user)
    active.where(user: user).order(updated_at: :desc).first
  end

  # The AI-derived template awaiting the user's review, if any.
  def self.proposal_for(user)
    proposed.find_by(user: user)
  end

  # What a user may build estimates on: their personal template (if agreed)
  # and the shared default. Never other users' templates or proposals.
  def self.available_to(user)
    [ personal_for(user), default ].compact
  end

  # Assign sections from the edit form's rows: one Hash per section with
  # "name", "hint", and newline-separated "typical_items". Blank-named rows
  # are dropped; order is preserved.
  def sections_form=(rows)
    self.sections = Array(rows).map { |row| row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h : row.to_h }
      .map { |row| row.transform_keys(&:to_s) }
      .select { |row| row["name"].to_s.strip.present? }
      .map do |row|
        {
          "name" => row["name"].to_s.strip,
          "hint" => row["hint"].to_s.strip,
          "typical_items" => row["typical_items"].to_s.split(/\r?\n/).map(&:strip).reject(&:blank?)
        }
      end
  end

  # Copy this (global) template into an active personal template for the
  # user so they can adjust it. Returns nil when they already have one.
  def customise_for(user)
    return nil if self.class.personal_for(user)
    # Names are globally unique, and two builders can share a display name —
    # the second copy would raise on create. Disambiguate rather than 500.
    base = "#{user.name} — #{name}".truncate(120)
    base = "#{base} (#{user.id})" if self.class.exists?(name: base)
    self.class.create!(
      user: user,
      status: "active",
      name: base,
      description: "Customised from #{name}.",
      sections: sections.deep_dup
    )
  end

  private

  def sections_must_be_named
    return if sections.blank?
    errors.add(:sections, "must all have a name") if sections.any? { |s| s["name"].to_s.strip.blank? }
  end
end
