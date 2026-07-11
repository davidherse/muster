class UserMailer < ApplicationMailer
  def activation(user)
    @user = user
    @activation_url = activation_url(token: user.generate_token_for(:activation))
    mail to: user.email_address, subject: "Activate your Muster account"
  end
end
