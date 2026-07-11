class PagesController < ApplicationController
  allow_unauthenticated_access

  def home
    redirect_to estimates_path and return if authenticated?
    @signup = EarlyAccessSignup.new
  end
end
