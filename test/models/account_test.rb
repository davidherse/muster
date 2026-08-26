require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "fixtures: built has one owner and one member" do
    built = accounts(:built)
    assert_equal users(:one), built.owner
    assert_equal %w[member owner], built.users.pluck(:role).sort
  end

  test "estimates created through a user land in the user's account" do
    estimate = users(:two).estimates.create!(name: "Shared job")
    assert_equal accounts(:built), estimate.account
    assert_includes accounts(:built).estimates, estimate
  end

  test "training documents created through a user land in the user's account" do
    doc = users(:two).training_documents.create!(name: "Doc")
    assert_equal accounts(:built), doc.account
  end

  test "current account follows the session user" do
    Current.session = users(:one).sessions.create!
    assert_equal accounts(:built), Current.account
  ensure
    Current.reset
  end

  test "role is validated" do
    user = users(:two)
    user.role = "boss"
    assert_not user.valid?
    assert users(:one).owner?
    assert_not users(:two).owner?
  end

  test "removing a seat keeps its work in the account, unattributed" do
    estimate = users(:two).estimates.create!(name: "Sam's job")
    doc = users(:two).training_documents.create!(name: "Sam's doc")
    users(:two).destroy!
    assert_nil estimate.reload.user
    assert_equal accounts(:built), estimate.account
    assert_nil doc.reload.user
  end
end
