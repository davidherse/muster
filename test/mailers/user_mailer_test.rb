require "test_helper"

class UserMailerTest < ActionMailer::TestCase
  test "activation email carries a working token link" do
    user = users(:unactivated)
    email = UserMailer.activation(user)
    assert_equal [ user.email_address ], email.to
    assert_match %r{/activate/}, email.html_part.body.to_s
    token = email.text_part.body.to_s[%r{/activate/([^\s]+)}, 1]
    assert_equal user, User.find_by_token_for(:activation, token)
  end
end
