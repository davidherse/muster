require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "root sends visitors to sign in" do
    get root_url
    assert_redirected_to new_session_url
  end

  test "root sends signed-in users to their estimates" do
    sign_in_as users(:one)
    get root_url
    assert_redirected_to estimates_url
  end
end
