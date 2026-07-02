require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "signup creates unactivated user and sends activation email" do
    assert_difference("User.count") do
      assert_enqueued_emails 1 do
        post registration_url, params: { user: {
          name: "New Builder", email_address: "builder@example.com",
          password: "password123", password_confirmation: "password123"
        } }
      end
    end
    assert_redirected_to new_session_url
    assert_not User.find_by(email_address: "builder@example.com").activated?
  end

  test "rejects invalid signup" do
    assert_no_difference("User.count") do
      post registration_url, params: { user: { name: "", email_address: "bad", password: "short", password_confirmation: "short" } }
    end
    assert_response :unprocessable_entity
  end
end
