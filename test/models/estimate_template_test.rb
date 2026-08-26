require "test_helper"

class EstimateTemplateTest < ActiveSupport::TestCase
  setup do
    @default = estimate_templates(:standard)
    @account = accounts(:built)
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

  test "available_to lists the account's template then the default, never another account's" do
    other = EstimateTemplate.create!(name: "Other's", account: accounts(:other), status: "active", sections: [ { "name" => "A" } ])
    proposal = EstimateTemplate.create!(name: "Proposal", account: @account, status: "proposed", sections: [ { "name" => "A" } ])
    assert_equal [ @default ], EstimateTemplate.available_to(@account)

    mine = EstimateTemplate.create!(name: "Mine", account: @account, status: "active", sections: [ { "name" => "A" } ])
    assert_equal [ mine, @default ], EstimateTemplate.available_to(@account)
    assert_not_includes EstimateTemplate.available_to(@account), other
    assert_not_includes EstimateTemplate.available_to(@account), proposal
  end

  test "customise_for copies the default into an active account template once" do
    copy = @default.customise_for(@account)
    assert copy.persisted?
    assert_equal @account, copy.account
    assert_equal "active", copy.status
    assert_equal "Built Homes — Test Standard", copy.name
    assert_equal @default.sections, copy.sections
    assert_equal copy, EstimateTemplate.active_for(@account)

    assert_nil @default.customise_for(@account), "refuses when the account already has a template"
  end

  test "customise_for disambiguates when another account shares a display name" do
    @default.customise_for(@account)
    twin = Account.create!(name: "Built Homes")

    copy = @default.customise_for(twin)
    assert copy.persisted?, "a shared display name must not blow up the copy"
    assert_equal twin, copy.account
    assert_equal "Built Homes — Test Standard (#{twin.id})", copy.name
    assert_equal @default.sections, copy.sections
  end

  test "active_for and proposal_for" do
    assert_nil EstimateTemplate.active_for(@account)
    assert_nil EstimateTemplate.proposal_for(@account)
    proposal = EstimateTemplate.create!(name: "P", account: @account, status: "proposed", sections: [ { "name" => "A" } ])
    assert_equal proposal, EstimateTemplate.proposal_for(@account)
    proposal.activate!
    assert_equal proposal, EstimateTemplate.active_for(@account)
    assert_nil EstimateTemplate.proposal_for(@account)
  end
end
