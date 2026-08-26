require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_invite_code = ENV["MUSTER_INVITE_CODE"]
    ENV["MUSTER_INVITE_CODE"] = "MUSTER-BETA"
  end

  teardown do
    ENV["MUSTER_INVITE_CODE"] = @original_invite_code
  end

  test "signup creates unactivated user and sends activation email" do
    assert_difference("User.count") do
      assert_enqueued_emails 1 do
        post registration_url, params: { registration: { invite_code: "MUSTER-BETA" }, user: {
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
      post registration_url, params: { registration: { invite_code: "MUSTER-BETA" }, user: { name: "", email_address: "bad", password: "short", password_confirmation: "short" } }
    end
    assert_response :unprocessable_entity
  end

  test "signup creates an account owned by the new user, named from company" do
    assert_difference "Account.count", 1 do
      post registration_url, params: { registration: { invite_code: "MUSTER-BETA", company: "Acme Builders" }, user: {
        name: "Ann", email_address: "ann@example.com", password: "password-123", password_confirmation: "password-123" } }
    end
    user = User.find_by!(email_address: "ann@example.com")
    assert user.owner?
    assert_equal "Acme Builders", user.account.name
    assert_not_nil user.password_set_at
  end

  test "signup without a company names the workspace after the person" do
    post registration_url, params: { registration: { invite_code: "MUSTER-BETA" }, user: {
      name: "Ann", email_address: "ann2@example.com", password: "password-123", password_confirmation: "password-123" } }
    assert_equal "Ann's workspace", User.find_by!(email_address: "ann2@example.com").account.name
  end

  test "wrong invite code shows only the closed-beta message" do
    assert_no_difference "Account.count" do
      post registration_url, params: { registration: { invite_code: "wrong" }, user: {
        name: "Ann", email_address: "ann3@example.com", password: "password-123", password_confirmation: "password-123" } }
    end
    assert_response :unprocessable_entity
    assert_match "closed beta", response.body
    assert_no_match(/Account must exist/, response.body)
  end
end
