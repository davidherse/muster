class RegistrationsController < ApplicationController
  allow_unauthenticated_access
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_registration_path, alert: "Try again later." }

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    unless valid_invite_code?
      @user.validate
      @user.errors.add(:base, "Muster is in closed beta — an invite code is required. Join the wait list on the homepage.")
      return render :new, status: :unprocessable_entity
    end
    if @user.save
      UserMailer.activation(@user).deliver_later
      redirect_to new_session_path, notice: "Almost there! Check your email to activate your account."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def valid_invite_code?
    code = params.dig(:registration, :invite_code) || params[:invite_code]
    ActiveSupport::SecurityUtils.secure_compare(code.to_s.strip.upcase, ENV.fetch("MUSTER_INVITE_CODE", "MUSTER-BETA"))
  end

  def user_params
    params.expect(user: [ :name, :email_address, :password, :password_confirmation ])
  end
end
