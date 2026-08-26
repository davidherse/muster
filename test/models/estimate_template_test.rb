require "test_helper"

class EstimateTemplateTest < ActiveSupport::TestCase
  setup do
    @default = estimate_templates(:standard)
    @user = users(:two)
  end

  test "sections_form= drops blank rows, strips, and splits typical items on newlines" do
    template = EstimateTemplate.new(name: "T")
    template.sections_form = [
      { "name" => "  Prelims ", "hint" => " Setup ", "typical_items" => "Supervision (Hour)\n\n  Skip bin (ea)  \n" },
      { "name" => "", "hint" => "ignored", "typical_items" => "x" },
      { "name" => "Painting", "hint" => "", "typical_items" => "" }
    ]
    assert_equal [
      { "name" => "Prelims", "hint" => "Setup", "typical_items" => [ "Supervision (Hour)", "Skip bin (ea)" ] },
      { "name" => "Painting", "hint" => "", "typical_items" => [] }
    ], template.sections
  end

  test "every section needs a name" do
    template = EstimateTemplate.new(name: "T", sections: [ { "name" => "", "hint" => "x" } ])
    assert_not template.valid?
    assert_includes template.errors[:sections], "must all have a name"
  end

  test "available_to lists the user's personal template then the default, never others'" do
    other = EstimateTemplate.create!(name: "Other's", user: users(:one), status: "active", sections: [ { "name" => "A" } ])
    proposal = EstimateTemplate.create!(name: "Proposal", user: @user, status: "proposed", sections: [ { "name" => "A" } ])
    assert_equal [ @default ], EstimateTemplate.available_to(@user)

    mine = EstimateTemplate.create!(name: "Mine", user: @user, status: "active", sections: [ { "name" => "A" } ])
    assert_equal [ mine, @default ], EstimateTemplate.available_to(@user)
    assert_not_includes EstimateTemplate.available_to(@user), other
    assert_not_includes EstimateTemplate.available_to(@user), proposal
  end

  test "customise_for copies the default into an active personal template once" do
    copy = @default.customise_for(@user)
    assert copy.persisted?
    assert_equal @user, copy.user
    assert_equal "active", copy.status
    assert_equal "#{@user.name} — #{@default.name}", copy.name
    assert_equal @default.sections, copy.sections
    assert_equal copy, EstimateTemplate.personal_for(@user)

    assert_nil @default.customise_for(@user), "refuses when a personal template already exists"
  end

  test "customise_for disambiguates when another user shares a display name" do
    @default.customise_for(@user)
    twin = User.create!(name: @user.name, email_address: "dup@example.com",
      password: "password-123", activated_at: Time.current, account: @user.account)

    copy = @default.customise_for(twin)
    assert copy.persisted?, "a shared display name must not blow up the copy"
    assert_equal twin, copy.user
    assert_equal "#{twin.name} — #{@default.name} (#{twin.id})", copy.name
    assert_equal @default.sections, copy.sections
  end

  test "personal_for and proposal_for" do
    assert_nil EstimateTemplate.personal_for(@user)
    assert_nil EstimateTemplate.proposal_for(@user)
    proposal = EstimateTemplate.create!(name: "P", user: @user, status: "proposed", sections: [ { "name" => "A" } ])
    assert_equal proposal, EstimateTemplate.proposal_for(@user)
    proposal.activate!
    assert_equal proposal, EstimateTemplate.personal_for(@user)
    assert_nil EstimateTemplate.proposal_for(@user)
  end
end
