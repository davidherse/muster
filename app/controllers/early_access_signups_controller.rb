class EarlyAccessSignupsController < ApplicationController
  allow_unauthenticated_access

  def create
    @signup = EarlyAccessSignup.find_or_initialize_by(email: params.dig(:early_access_signup, :email))
    @signup.assign_attributes(params.require(:early_access_signup).permit(:name, :company))
    if @signup.save
      redirect_to root_path(joined: 1), notice: "You're on the list — we'll be in touch as beta places open up."
    else
      redirect_to root_path, alert: @signup.errors.full_messages.to_sentence
    end
  end
end
