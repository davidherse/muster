class PagesController < ApplicationController
  allow_unauthenticated_access

  # The marketing homepage is retired on self-hosted instances: root is a
  # door, not a page.
  def home
    if authenticated?
      redirect_to estimates_path
    else
      redirect_to new_session_path
    end
  end
end
