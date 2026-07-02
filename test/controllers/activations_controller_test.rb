require "test_helper"

class ActivationsControllerTest < ActionDispatch::IntegrationTest
  test "valid token activates the account" do
    user = users(:unactivated)
    get activation_url(token: user.generate_token_for(:activation))
    assert_redirected_to new_session_url
    assert user.reload.activated?
  end

  test "garbage token does not activate" do
    get activation_url(token: "nope")
    assert_redirected_to new_session_url
    assert_match(/invalid or has expired/, flash[:alert])
  end
end
