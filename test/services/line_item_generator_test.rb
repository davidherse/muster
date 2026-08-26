require "test_helper"

class LineItemGeneratorTest < ActiveSupport::TestCase
  # The questionnaire's fullest repaint option: it names character fabric
  # whatever the building's age, so the extent alone can never pick the
  # heritage composite.
  FULL_EXTENT = "Full repaint inside and out, incl. retained linings (VJ, trim, fretwork)".freeze

  setup do
    @estimate = users(:one).estimates.create!(name: "Drayton", estimate_template: estimate_templates(:standard))
    @analysis = FakeAiClient.new.send(:default_analysis)
  end

  # --- repaint composite class -------------------------------------------

  test "a stated post-1990 era rules out the heritage composite" do
    @estimate.update!(questionnaire: { "repaint_extent" => FULL_EXTENT, "building_era" => "Post-1990" })
    generator = LineItemGenerator.new(@estimate, analysis: @analysis.merge("internal_lining_type" => "VJ"), client: FakeAiClient.new)

    assert_equal "full repaint of standard character home", generator.send(:repaint_class)
  end

  test "a character era with character fabric in the extent gets the heritage composite" do
    @estimate.update!(questionnaire: { "repaint_extent" => FULL_EXTENT, "building_era" => "Pre-1946 (character)" })
    generator = LineItemGenerator.new(@estimate, analysis: @analysis.merge("internal_lining_type" => "VJ"), client: FakeAiClient.new)

    assert_equal "full heritage repaint", generator.send(:repaint_class)
  end

  test "with no stated era the analysis lining type stands in as character evidence" do
    @estimate.update!(questionnaire: { "repaint_extent" => FULL_EXTENT })
    generator = LineItemGenerator.new(@estimate, analysis: @analysis.merge("internal_lining_type" => "VJ boards"), client: FakeAiClient.new)

    assert_equal "full heritage repaint", generator.send(:repaint_class)
  end

  # --- crew labour for the build duration ---------------------------------

  test "the crew labour rule carries the template's section name and the duration in weeks" do
    @estimate.update!(estimate_template: crew_template, questionnaire: { "duration_months" => "12" })

    system = system_text(generate)
    assert_includes system, "CREW LABOUR FOR THE BUILD DURATION"
    assert_includes system, "52 weeks"
    assert_includes system, "In the 'Carpentry & General Labour' section"
  end

  test "no crew labour rule without a stated duration" do
    @estimate.update!(estimate_template: crew_template)

    refute_includes system_text(generate), "CREW LABOUR FOR THE BUILD DURATION"
  end

  test "no crew labour rule when the template has no crew section" do
    @estimate.update!(questionnaire: { "duration_months" => "12" })

    refute_includes system_text(generate), "CREW LABOUR FOR THE BUILD DURATION"
  end

  # --- supervision ---------------------------------------------------------

  test "supervision is always costed in one section only" do
    assert_includes system_text(generate), "SUPERVISION ONCE"
  end

  private

  def generate(sections = [ { "name" => "Preliminaries", "hint" => "" } ])
    client = FakeAiClient.new
    LineItemGenerator.new(@estimate.reload, analysis: @analysis, client: client).call(sections)
    client
  end

  def system_text(client)
    client.calls.last[:system].map { |block| block[:text] }.join("\n")
  end

  def crew_template
    EstimateTemplate.create!(
      name: "Crew", account: accounts(:built), status: "active",
      sections: [
        { "name" => "Preliminaries", "hint" => "" },
        { "name" => "Carpentry & General Labour", "hint" => "Crew for the duration",
          "typical_items" => [ "Carpentry and Onsite Labour per week (average 2 men) (weeks)" ] },
        { "name" => "Lockup Carpenter", "hint" => "" }
      ]
    )
  end
end
