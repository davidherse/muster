class ActivationsController < ApplicationController
  allow_unauthenticated_access

  def show
    user = User.find_by_token_for(:activation, params[:token])
    if user
      user.activate!
      redirect_to new_session_path, notice: "Your account is activated. Please sign in."
    else
      redirect_to new_session_path, alert: "That activation link is invalid or has expired. Sign up again to receive a new one."
    end
  end
end
