require "test_helper"

class TeamControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:one)
    @member = users(:two)
  end

  test "requires authentication" do
    get team_url
    assert_redirected_to new_session_url
  end

  test "owner sees members with controls" do
    sign_in_as @owner
    get team_url
    assert_response :success
    assert_match "Sam Renovator", response.body
    assert_no_match(/Olive Outsider/, response.body)
    assert_select "form[action=?]", team_members_path
    assert_select "form[action=?]", team_member_path(@member)
    assert_select "form[action=?]", team_member_path(@owner), count: 0
  end

  test "member sees the team read-only" do
    sign_in_as @member
    get team_url
    assert_response :success
    assert_select "form[action=?]", team_members_path, count: 0
    assert_select "form[action=?]", team_member_path(@member), count: 0
  end

  test "owner adds a seat and gets a set-password link that works" do
    sign_in_as @owner
    assert_difference "accounts(:built).users.count", 1 do
      post team_members_url, params: { user: { name: "Brenden", email_address: "brenden@example.com" } }
    end
    seat = User.find_by!(email_address: "brenden@example.com")
    assert_equal accounts(:built), seat.account
    assert_equal "member", seat.role
    assert seat.activated?
    assert_nil seat.password_set_at
    assert_redirected_to team_url
    follow_redirect!
    link = response.body[%r{https?://[^"<\s]+/passwords/[^"<\s]+/edit}]
    assert link, "set-password link not shown"
    get link
    assert_response :success
  end

  test "member cannot add, remove, rename, or reset" do
    sign_in_as @member
    assert_no_difference "User.count" do
      post team_members_url, params: { user: { name: "X", email_address: "x@example.com" } }
    end
    assert_redirected_to team_url
    delete team_member_url(@owner)
    assert_redirected_to team_url
    assert User.exists?(@owner.id)
    patch rename_team_url, params: { account: { name: "Hijacked" } }
    assert_equal "Built Homes", accounts(:built).reload.name
    post reset_link_team_member_url(@owner)
    assert_redirected_to team_url
  end

  test "owner cannot be removed; removing a member keeps their estimates" do
    sign_in_as @owner
    estimate = @member.estimates.create!(name: "Sam's job")
    delete team_member_url(@owner)
    assert User.exists?(@owner.id)
    delete team_member_url(@member)
    assert_redirected_to team_url
    assert_not User.exists?(@member.id)
    assert_nil estimate.reload.user
    assert_equal accounts(:built), estimate.account
  end

  test "owner regenerates a set-password link for any member" do
    sign_in_as @owner
    post reset_link_team_member_url(@member)
    assert_redirected_to team_url
    follow_redirect!
    assert_match %r{/passwords/[^"<\s]+/edit}, response.body
  end

  test "owner renames the workspace" do
    sign_in_as @owner
    patch rename_team_url, params: { account: { name: "Built Homes Pty Ltd" } }
    assert_redirected_to team_url
    assert_equal "Built Homes Pty Ltd", accounts(:built).reload.name
  end

  test "cannot remove a user from another account" do
    sign_in_as @owner
    delete team_member_url(users(:outsider))
    assert_response :not_found
  end
end
