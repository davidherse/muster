class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :estimates, dependent: :destroy
  has_many :training_documents, dependent: :destroy
  has_many :price_book_items, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :name, presence: true
  validates :email_address, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true

  generates_token_for :activation, expires_in: 2.days

  def activated?
    activated_at.present?
  end

  def activate!
    update!(activated_at: Time.current) unless activated?
  end
end
