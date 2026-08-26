# A builder's workspace: every seat in the account shares its estimates,
# template, training documents, learned price book and quantity norms.
class Account < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :estimates, dependent: :destroy
  has_many :training_documents, dependent: :destroy
  has_many :estimate_templates, dependent: :destroy
  has_many :price_book_items, dependent: :destroy

  validates :name, presence: true

  def owner
    users.find_by(role: "owner")
  end

  def onboarded?
    onboarded_at.present?
  end
end
