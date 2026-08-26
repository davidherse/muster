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
    assert_includes system, "Site Labourer per week"
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

  # --- painting composite ---------------------------------------------------

  test "the painting bullet lists the premium class and yields to a quoted Painting section" do
    bullet = painting_rule_text(generate).squish

    assert_includes bullet, "full repaint, premium finish"
    assert_includes bullet, "unless a supplier quote covers the Painting section"
  end

  # --- supplier quotes ------------------------------------------------------

  test "quoted trades rule names the supplier, amount and section only when quotes exist" do
    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.quoted_analysis, client: client).call(steel_batch)
    system = client.calls.last[:system].map { |b| b[:text] || b["text"] }.join
    assert_match(/^- QUOTED TRADES ARE BINDING:/, system)
    assert_match "West Tiling", system
    assert_match "12000", system.delete(",")
    assert_match "Structural Steel", system

    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.new.send(:default_analysis), client: client).call(steel_batch)
    assert_no_match(/^- QUOTED TRADES ARE BINDING:/, client.calls.last[:system].map { |b| b[:text] || b["text"] }.join)
  end

  # Every batch sees every quote, worded identically, so the model can never
  # read "listed here" as "cost it here" and emit an off-batch section — a
  # section the generator would find-or-create, then the real batch would
  # append to, double-counting the quote.
  test "a batch the quotes do not cover still sees them, listed for information only" do
    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.quoted_analysis, client: client)
      .call([ { "name" => "Preliminaries", "hint" => "" } ])
    off_batch = quotes_rule_text(client)

    assert_match "West Tiling", off_batch
    assert_match "covers: Structural Steel", off_batch
    assert_match "Only act on a quote whose covered sections are IN THIS", off_batch
    assert_match "must not produce lines here", off_batch

    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: FakeAiClient.quoted_analysis, client: client).call(steel_batch)
    assert_equal off_batch, quotes_rule_text(client)
  end

  test "quote lines carry GST provenance, never the extractor's status token" do
    ex = quotes_rule_text(generate_quotes({ "gst_status" => "ex_gst" }))
    assert_includes ex, "$12000 ex GST | includes:"
    refute_includes ex, "(ex_gst)"

    inc = quotes_rule_text(generate_quotes({ "gst_status" => "inc_gst" }))
    assert_includes inc, "$12000 ex GST (converted from the document's inc-GST total) | includes:"
    refute_includes inc, "(inc_gst)"

    unclear = quotes_rule_text(generate_quotes({ "gst_status" => "unclear" }))
    assert_includes unclear,
                    "$12000 ex GST (GST status unclear on the document — treated as ex GST; note it in assumptions) | includes:"
    refute_includes unclear, "(unclear)"
  end

  test "fields are pipe separated so a multi-entry excludes list cannot blur into covers" do
    text = quotes_rule_text(generate_quotes({ "excludes" => [ "crane hire", "scaffold" ] }))

    assert_includes text, "excludes: crane hire, scaffold | covers: Structural Steel"
  end

  test "a quote with no usable total is informational, never binding" do
    system = system_text(generate_quotes({ "amount_ex_gst" => 0 }))

    assert_no_match(/^- QUOTED TRADES ARE BINDING:/, system)
    assert_includes system, "QUOTES WITHOUT A USABLE TOTAL (price these trades from rates as usual)"
    assert_includes system, "West Tiling"
  end

  test "a mix of quotes binds the priced one and lists the unpriced one apart" do
    client = generate_quotes({ "supplier" => "Bayside Steel" },
                             { "supplier" => "Nowhere Plumbing", "trade" => "Plumbing",
                               "amount_ex_gst" => 0.0, "sections" => [ "Plumbing" ] })
    bound, _, unpriced = quotes_rule_text(client).partition("- QUOTES WITHOUT A USABLE TOTAL")

    assert_includes bound, "QUOTED TRADES ARE BINDING"
    assert_includes bound, "Bayside Steel"
    refute_includes bound, "Nowhere Plumbing"
    assert_includes unpriced, "Nowhere Plumbing"
    refute_includes unpriced, "Bayside Steel"
  end

  test "a priced quote outranks the books, PC allowances and the measured takeoff" do
    assert_includes quotes_rule_text(generate_quotes).squish,
                    "Precedence: for a section a priced quote covers, the quote outranks every other binding rule — " \
                    "user and base book rates, PC allowances, and measured takeoff quantities — which then apply " \
                    "only to the builder-side items the quote excludes."
  end

  # --- premium repaint composite -------------------------------------------

  test "premium repaint class for high-end finishes, standard otherwise, heritage untouched" do
    @estimate.update!(questionnaire: { "repaint_extent" => "Full repaint inside and out", "building_era" => "Post-1990" })
    assert_equal "full repaint, premium finish", generator_with(finish_level: "high_end").send(:repaint_class)
    assert_equal "full repaint, premium finish", generator_with(finish_level: "luxury").send(:repaint_class)
    assert_equal "full repaint of standard character home", generator_with(finish_level: "standard").send(:repaint_class)
    @estimate.update!(questionnaire: { "repaint_extent" => "Full repaint incl. VJ linings and fretwork", "building_era" => "Pre-1946 character home" })
    assert_equal "full heritage repaint", generator_with(finish_level: "high_end").send(:repaint_class)

    # The classes ahead of premium in the order keep their jobs: a high-end
    # raise still gets the raise composite, and a high-end selective scope is
    # still selective — premium never promotes a smaller class.
    @estimate.update!(questionnaire: { "repaint_extent" => "Full repaint inside and out", "building_era" => "Post-1990" })
    assert_equal "full repaint incl raise/build-under new lower level",
                 generator_with(finish_level: "high_end", project_class: "raise_and_build_under").send(:repaint_class)
    @estimate.update!(questionnaire: { "repaint_extent" => "Selective — new work plus touch-ups", "building_era" => "Post-1990" })
    assert_equal "selective scope", generator_with(finish_level: "high_end").send(:repaint_class)
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

  def generator_with(finish_level:, project_class: nil)
    analysis = FakeAiClient.new.send(:default_analysis).merge("finish_level" => finish_level)
    analysis["project_class"] = project_class if project_class
    LineItemGenerator.new(@estimate, analysis: analysis, client: FakeAiClient.new)
  end

  # The quotes rules as rendered into the system prompt — the binding block,
  # the unpriced list, or both — up to the bullet that follows them.
  def quotes_rule_text(client)
    system_text(client)[/^- QUOTE[DS] .*?(?=^- PC allowances)/m].to_s.strip
  end

  # The painting bullet as rendered, up to the bullet that follows it.
  def painting_rule_text(client)
    system_text(client)[/^- Painting:.*?(?=^- Windows and doors)/m].to_s.strip
  end

  # A generator run over the steel batch whose analysis carries one quote per
  # hash of overrides, each merged onto the default quote.
  def generate_quotes(*overrides)
    overrides = [ {} ] if overrides.empty?
    base = FakeAiClient.quoted_analysis["supplier_quotes"].first
    analysis = FakeAiClient.quoted_analysis.merge("supplier_quotes" => overrides.map { |o| base.merge(o) })
    client = FakeAiClient.new
    LineItemGenerator.new(@estimate, analysis: analysis, client: client).call(steel_batch)
    client
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
