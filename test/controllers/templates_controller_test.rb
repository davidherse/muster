require "test_helper"

class TemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @user = users(:two)
    @default = estimate_templates(:standard)
  end

  test "requires authentication" do
    get templates_url
    assert_redirected_to new_session_url
  end

  test "index shows the default and offers customise when there is no personal template" do
    sign_in_as @user
    get templates_url
    assert_response :success
    assert_match @default.name, response.body
    assert_match "Customise", response.body
    assert_no_match(/Re-derive/, response.body)
  end

  test "index shows my personal template and hides customise" do
    sign_in_as @user
    mine = EstimateTemplate.create!(name: "Mine", user: @user, status: "active", sections: [ { "name" => "Demolition", "hint" => "" } ])
    get templates_url
    assert_response :success
    assert_match "Mine", response.body
    assert_match "Demolition", response.body
    assert_match edit_template_path(mine), response.body
    assert_no_match(/Customise/, response.body)
  end

  test "index offers editing the default only to admins" do
    sign_in_as @user
    get templates_url
    assert_no_match edit_template_path(@default), response.body

    sign_in_as @admin
    get templates_url
    assert_match edit_template_path(@default), response.body
  end

  test "index shows a pending proposal with accept and discard" do
    sign_in_as @user
    EstimateTemplate.create!(name: "Proposal", user: @user, status: "proposed", sections: [ { "name" => "Wet Areas", "hint" => "" } ])
    get templates_url
    assert_match "Wet Areas", response.body
    assert_match accept_templates_path, response.body
    assert_match discard_templates_path, response.body
  end

  test "index offers re-derive only with completed training documents" do
    sign_in_as @user
    @user.training_documents.create!(name: "Doc", status: "completed")
    get templates_url
    assert_match "Re-derive", response.body
  end
end
