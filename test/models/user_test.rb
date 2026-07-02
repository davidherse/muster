require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "requires name, valid email, and 8+ char password" do
    user = User.new(name: "", email_address: "bad", password: "short")
    assert_not user.valid?
    assert user.errors[:name].any?
    assert user.errors[:email_address].any?
    assert user.errors[:password].any?
  end

  test "activate! sets activated_at once" do
    user = users(:unactivated)
    assert_not user.activated?
    user.activate!
    assert user.activated?
    first = user.activated_at
    user.activate!
    assert_equal first, user.reload.activated_at
  end

  test "activation token round trips" do
    user = users(:unactivated)
    token = user.generate_token_for(:activation)
    assert_equal user, User.find_by_token_for(:activation, token)
  end
end
