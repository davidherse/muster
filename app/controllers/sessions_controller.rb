class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      if user.activated?
        start_new_session_for user
        if user.onboarded_at.nil? && user.estimates.none?
          redirect_to onboarding_path
        else
          redirect_to after_authentication_url
        end
      else
        UserMailer.activation(user).deliver_later
        redirect_to new_session_path, alert: "Your account isn't activated yet. We've re-sent the activation email."
      end
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
