class EstimateTemplate < ApplicationRecord
  belongs_to :account, optional: true
  has_many :estimates, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :sections, presence: true
  validate :sections_must_be_named

  STATUSES = %w[proposed active].freeze
  validates :status, inclusion: { in: STATUSES }

  scope :global, -> { where(account_id: nil) }
  scope :active, -> { where(status: "active") }
  scope :proposed, -> { where(status: "proposed") }

  # sections is an ordered array of {"name" => ..., "hint" => ...} hashes.
  # Synthesized account templates also carry "typical_items" => [...] per
  # section — the line items this builder usually breaks the section into.
  def section_names
    sections.map { |s| s["name"] }
  end

  def account?
    account_id.present?
  end

  # Agreeing a proposal makes it the account's template; any previous
  # account template is superseded.
  def activate!
    transaction do
      self.class.where(account: account).where.not(id: id).destroy_all if account?
      update!(status: "active")
    end
  end

  # The shared starting template for accounts with no agreed template.
  def self.default
    global.active.order(:id).first
  end

  # The account's agreed template, if any.
  def self.active_for(account)
    active.where(account: account).order(updated_at: :desc).first
  end

  # The AI-derived template awaiting the account's review, if any.
  def self.proposal_for(account)
    proposed.find_by(account: account)
  end

  # The template an account's estimates are built on: its agreed template,
  # else the shared default.
  def self.for_account(account)
    return default unless account
    active_for(account) || default
  end

  # What an account may build estimates on: its own template (if agreed) and
  # the shared default. Never another account's template or a proposal.
  def self.available_to(account)
    [ active_for(account), default ].compact
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

  # Copy this (global) template into an active template the account can
  # adjust. Returns nil when the account already has one.
  def customise_for(account)
    return nil if self.class.active_for(account)
    # Names are globally unique, and two builders can share a display name —
    # the second copy would raise on create. Disambiguate rather than 500.
    base = "#{account.name} — #{name}".truncate(120)
    base = "#{base} (#{account.id})" if self.class.exists?(name: base)
    self.class.create!(
      account: account,
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
