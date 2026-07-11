class EarlyAccessSignup < ApplicationRecord
  normalizes :email, with: ->(e) { e.strip.downcase }
  validates :email, presence: true, uniqueness: true,
                    format: { with: URI::MailTo::EMAIL_REGEXP, message: "doesn't look like an email address" }
end
