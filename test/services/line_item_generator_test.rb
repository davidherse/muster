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

  test "the 1946 to 1990 era is not heritage" do
    @estimate.update!(questionnaire: { "repaint_extent" => FULL_EXTENT, "building_era" => "1946–1990" })
    generator = LineItemGenerator.new(@estimate, analysis: @analysis.merge("internal_lining_type" => "VJ"), client: FakeAiClient.new)

    assert_equal "full repaint of standard character home", generator.send(:repaint_class)
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

  # --- supplier quotes ------------------------------------------------------

  test "quoted trades rule names the supplier, amount and section only when quotes exist" do
    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.quoted_analysis, client: client).call(steel_batch)
    system = client.calls.last[:system].map { |b| b[:text] || b["text"] }.join
    assert_match "QUOTED TRADES ARE BINDING", system
    assert_match "West Tiling", system
    assert_match "12000", system.delete(",")
    assert_match "Structural Steel", system

    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.new.send(:default_analysis), client: client).call(steel_batch)
    assert_no_match(/QUOTED TRADES ARE BINDING/, client.calls.last[:system].map { |b| b[:text] || b["text"] }.join)
  end

  # --- premium repaint composite -------------------------------------------

  test "premium repaint class for high-end finishes, standard otherwise, heritage untouched" do
    @estimate.update!(questionnaire: { "repaint_extent" => "Full repaint inside and out", "building_era" => "Post-1990" })
    assert_equal "full repaint, premium finish", generator_with(finish_level: "high_end").send(:repaint_class)
    assert_equal "full repaint, premium finish", generator_with(finish_level: "luxury").send(:repaint_class)
    assert_equal "full repaint of standard character home", generator_with(finish_level: "standard").send(:repaint_class)
    @estimate.update!(questionnaire: { "repaint_extent" => "Full repaint incl. VJ linings and fretwork", "building_era" => "Pre-1946 character home" })
    assert_equal "full heritage repaint", generator_with(finish_level: "high_end").send(:repaint_class)
  end

  # --- round-2 calibration rules -------------------------------------------

  test "supervision-by-duration and single-ducted-system rules are present" do
    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.new.send(:default_analysis), client: client).call(steel_batch)
    system = client.calls.last[:system].map { |b| b[:text] || b["text"] }.join
    assert_match "SUPERVISION BY DURATION", system
    assert_match "SINGLE DUCTED SYSTEM", system
  end

  private

  def steel_batch
    [ { "name" => "Structural Steel", "hint" => "Beams" } ]
  end

  def generator_with(finish_level:)
    LineItemGenerator.new(@estimate,
                          analysis: FakeAiClient.new.send(:default_analysis).merge("finish_level" => finish_level),
                          client: FakeAiClient.new)
  end

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
