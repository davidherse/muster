class TrainingDocument < ApplicationRecord
  STATUSES = %w[pending processing completed failed].freeze

  belongs_to :user
  has_many_attached :files

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }

  STATUSES.each { |s| define_method("#{s}?") { status == s } }
end
