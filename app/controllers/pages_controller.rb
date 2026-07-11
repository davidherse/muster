class PagesController < ApplicationController
  allow_unauthenticated_access

  def home
    @signup = EarlyAccessSignup.new
  end
end
