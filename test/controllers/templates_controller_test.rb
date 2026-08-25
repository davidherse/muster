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

  test "accepting or discarding a proposal asks for confirmation first" do
    sign_in_as @user
    EstimateTemplate.create!(name: "Proposal", user: @user, status: "proposed", sections: [ { "name" => "Wet Areas", "hint" => "" } ])
    get templates_url
    # Both destroy the user's current sections or the proposal outright.
    assert_select "form[action=?] [data-turbo-confirm]", accept_templates_path
    assert_select "form[action=?] [data-turbo-confirm]", discard_templates_path
  end

  test "index offers re-derive only with completed training documents" do
    sign_in_as @user
    @user.training_documents.create!(name: "Doc", status: "completed")
    get templates_url
    assert_match "Re-derive", response.body
  end

  test "deriving state expires after the window" do
    sign_in_as @user
    @user.training_documents.create!(name: "Doc", status: "completed")
    post rederive_templates_url
    get templates_url
    assert_match "Deriving your template", response.body

    travel 11.minutes
    get templates_url
    assert_match "Re-derive", response.body
    assert_no_match(/Deriving your template/, response.body)
  end

  test "deriving state is per user" do
    sign_in_as @user
    @user.training_documents.create!(name: "Doc", status: "completed")
    post rederive_templates_url

    sign_in_as @admin
    get templates_url
    assert_no_match(/Deriving your template/, response.body)
  end

  test "edit my personal template renders the section rows" do
    sign_in_as @user
    mine = EstimateTemplate.create!(name: "Mine", user: @user, status: "active",
      sections: [ { "name" => "Demolition", "hint" => "Strip out", "typical_items" => [ "Skip bin (ea)" ] } ])
    get edit_template_url(mine)
    assert_response :success
    assert_select "input[name='template[sections][][name]'][value='Demolition']"
    assert_select "input[name='template[sections][][hint]'][value='Strip out']"
    assert_select "textarea[name='template[sections][][typical_items]']", text: "Skip bin (ea)"
  end

  test "cannot edit another user's personal template" do
    sign_in_as @user
    theirs = EstimateTemplate.create!(name: "Theirs", user: @admin, status: "active", sections: [ { "name" => "A" } ])
    get edit_template_url(theirs)
    assert_redirected_to templates_url
    patch template_url(theirs), params: { template: { name: "Hijack", sections: [ { name: "B" } ] } }
    assert_redirected_to templates_url
    assert_equal "Theirs", theirs.reload.name
  end

  test "non-admins cannot edit the default, admins can" do
    sign_in_as @user
    get edit_template_url(@default)
    assert_redirected_to templates_url

    sign_in_as @admin
    get edit_template_url(@default)
    assert_response :success
  end

  test "update normalises rows and preserves order" do
    sign_in_as @user
    mine = EstimateTemplate.create!(name: "Mine", user: @user, status: "active", sections: [ { "name" => "Old" } ])
    patch template_url(mine), params: { template: { name: "Mine v2", sections: [
      { name: " Prelims ", hint: "Setup", typical_items: "Supervision (Hour)\r\n\r\nSkip bin (ea)" },
      { name: "", hint: "dropped", typical_items: "" },
      { name: "Painting", hint: "", typical_items: "" }
    ] } }
    assert_redirected_to templates_url
    mine.reload
    assert_equal "Mine v2", mine.name
    assert_equal [ "Prelims", "Painting" ], mine.section_names
    assert_equal [ "Supervision (Hour)", "Skip bin (ea)" ], mine.sections.first["typical_items"]
  end

  test "update with no named sections re-renders with an error" do
    sign_in_as @user
    mine = EstimateTemplate.create!(name: "Mine", user: @user, status: "active", sections: [ { "name" => "Old" } ])
    patch template_url(mine), params: { template: { name: "Mine", sections: [ { name: "", hint: "", typical_items: "" } ] } }
    assert_response :unprocessable_entity
    # A blank-named row is dropped by sections_form=, so the error is the
    # presence validation, rendered HTML-escaped as "Sections can&#39;t be blank".
    assert_match "Sections can", response.body
    assert_equal [ "Old" ], mine.reload.section_names
  end

  test "customise copies the default into a personal template and opens the editor" do
    sign_in_as @user
    post customise_templates_url
    copy = EstimateTemplate.personal_for(@user)
    assert copy.present?
    assert_redirected_to edit_template_url(copy)
    assert_equal @default.sections, copy.sections

    post customise_templates_url
    assert_redirected_to templates_url
    assert_equal 1, EstimateTemplate.active.where(user: @user).count
  end

  test "rederive enqueues synthesis when there are completed training documents" do
    sign_in_as @user
    post rederive_templates_url
    assert_redirected_to templates_url
    assert_match "Upload at least one", flash[:alert]

    @user.training_documents.create!(name: "Doc", status: "completed")
    assert_enqueued_with(job: SynthesizeTemplateJob, args: [ @user ]) do
      post rederive_templates_url
    end
    assert_redirected_to templates_url

    get templates_url
    assert_match "Deriving your template", response.body
    get status_templates_url
    assert_equal "processing", response.parsed_body["status"]
  end

  test "status stops reporting processing once the re-derive window expires" do
    sign_in_as @user
    @user.training_documents.create!(name: "Doc", status: "completed")
    post rederive_templates_url
    get status_templates_url
    assert_equal "processing", response.parsed_body["status"]

    # The job died without producing a proposal: the poll must reach a
    # terminal state so the page reloads and re-offers Re-derive.
    travel 11.minutes
    get status_templates_url
    assert_equal "ready", response.parsed_body["status"]
  end

  test "status keeps polling while training documents are still being read" do
    sign_in_as @user
    @user.training_documents.create!(name: "Doc", status: "processing")
    get status_templates_url
    assert_equal "processing", response.parsed_body["status"]

    # The index shows its spinner for exactly this state; if status called it
    # ready the page would reload every poll tick.
    get templates_url
    assert_match "Deriving your template", response.body
  end

  test "status reports ready once a proposal exists" do
    sign_in_as @user
    EstimateTemplate.create!(name: "P", user: @user, status: "proposed", sections: [ { "name" => "A" } ])
    get status_templates_url
    assert_equal "ready", response.parsed_body["status"]
  end

  test "accept activates the proposal and supersedes the previous personal template" do
    sign_in_as @user
    old = EstimateTemplate.create!(name: "Old", user: @user, status: "active", sections: [ { "name" => "A" } ])
    proposal = EstimateTemplate.create!(name: "P", user: @user, status: "proposed", sections: [ { "name" => "B" } ])
    post accept_templates_url
    assert_redirected_to templates_url
    assert_equal proposal, EstimateTemplate.personal_for(@user)
    assert_not EstimateTemplate.exists?(old.id)
  end

  test "accept without a proposal explains itself" do
    sign_in_as @user
    post accept_templates_url
    assert_redirected_to templates_url
    assert_match "no proposal", flash[:alert]
  end

  test "discard destroys the proposal and keeps the current template" do
    sign_in_as @user
    mine = EstimateTemplate.create!(name: "Mine", user: @user, status: "active", sections: [ { "name" => "A" } ])
    EstimateTemplate.create!(name: "P", user: @user, status: "proposed", sections: [ { "name" => "B" } ])
    delete discard_templates_url
    assert_redirected_to templates_url
    assert_nil EstimateTemplate.proposal_for(@user)
    assert_equal mine, EstimateTemplate.personal_for(@user)
  end
end
