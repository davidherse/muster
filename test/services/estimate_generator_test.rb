require "test_helper"

# Reads the estimate's claim straight from the database before each AI call
# and lets the test move the clock on, so a run's heartbeat is observable.
class ClaimProbeAiClient < FakeAiClient
  attr_reader :claim_times

  def initialize(estimate, tick, **options)
    super(**options)
    @estimate = estimate
    @tick = tick
    @claim_times = []
  end

  def complete_json(**)
    @claim_times << Estimate.find(@estimate.id).claimed_at
    @tick.call
    super
  end
end

# Records the estimate's status at the moment QuestionHarvester's schema is
# requested, so a test can prove the harvest ran before completion.
class StatusRecordingAiClient < FakeAiClient
  attr_reader :statuses

  def initialize(estimate_id, **options)
    super(**options)
    @estimate_id = estimate_id
    @statuses = []
  end

  def complete_json(system:, content:, schema:, max_tokens: nil)
    @statuses << Estimate.find(@estimate_id).status if schema == QuestionHarvester::SCHEMA
    super
  end
end

class EstimateGeneratorTest < ActiveSupport::TestCase
  setup do
    @estimate = users(:one).estimates.create!(name: "Reno", estimate_template: estimate_templates(:standard))
    @estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
  end

  test "generates sections, line items, totals, and range" do
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    @estimate.reload

    assert @estimate.completed?
    assert_equal "Renovation and extension", @estimate.building_type
    assert_equal %w[Preliminaries Structural\ Steel], @estimate.sections.map(&:name)
    assert_equal 4, @estimate.line_items.count

    # 2 sections x (2*100 + 10*70) = 1800
    assert_equal 1800.to_d, @estimate.total
    assert @estimate.total_low < @estimate.total
    assert @estimate.total_high > @estimate.total
    assert_equal 100, @estimate.progress
  end

  test "skips sections the model marks not applicable" do
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    assert_not @estimate.sections.exists?(name: "Solar Power System")
  end

  test "stores plan analysis on the estimate" do
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    assert_equal 210.0, @estimate.reload.plan_summary["floor_area_m2"]
    assert_equal "210.0", @estimate.floor_area
  end

  test "regenerating replaces previous sections" do
    generator = EstimateGenerator.new(@estimate, client: FakeAiClient.new)
    generator.call
    first_ids = @estimate.sections.pluck(:id)
    generator.call
    assert_empty first_ids & @estimate.reload.sections.pluck(:id)
    assert_equal 2, @estimate.sections.count
  end

  test "marks estimate failed with friendly message on AI error" do
    client = FakeAiClient.new(fail_with: Ai::Client::RefusalError.new("The model declined this request."))
    assert_raises(Ai::Client::RefusalError) do
      EstimateGenerator.new(@estimate, client: client).call
    end
    assert @estimate.reload.failed?
    assert_equal "The model declined this request.", @estimate.error_message
  end

  test "resume skips analysis and already-costed sections" do
    failing = FakeAiClient.new(fail_after: 3, fail_with: Ai::Client::Error.new("boom"))
    # batch_size 2 over 3 template sections => analysis (draft+verify) + batch1 succeed, batch2 raises
    assert_raises(Ai::Client::Error) do
      EstimateGenerator.new(@estimate, client: failing, batch_size: 2).call
    end
    @estimate.reload
    assert @estimate.failed?
    assert_equal %w[Preliminaries Structural\ Steel], @estimate.costed_sections
    sections_before = @estimate.sections.pluck(:id)

    good = FakeAiClient.new
    EstimateGenerator.new(@estimate, client: good, batch_size: 2).call(resume: true)
    @estimate.reload

    assert @estimate.completed?
    # resume must not re-run plan analysis
    assert good.calls.none? { |c| c[:schema] == PlanAnalyzer::SCHEMA }
    # only the remaining section was requested from the line item generator
    line_item_calls = good.calls.select { |c| c[:schema] == LineItemGenerator::SCHEMA }
    requested = line_item_calls.flat_map { |c| c[:content].map { |b| b[:text] } }.join
    assert_includes requested, "Solar Power System"
    refute_includes requested, "Preliminaries"
    # previously costed sections retained, not duplicated
    assert_equal sections_before.sort, (@estimate.sections.pluck(:id) & sections_before).sort
    assert_equal 2, @estimate.sections.count
    assert_equal 3, @estimate.costed_sections.size
  end

  test "fresh run resets costed sections" do
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    assert_equal 3, @estimate.reload.costed_sections.size
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    assert_equal 3, @estimate.reload.costed_sections.size
    assert_equal 2, @estimate.sections.count
  end

  test "a queued estimate the controller marked processing can be claimed" do
    @estimate.processing!("Queued for analysis…")
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    @estimate.reload
    assert @estimate.completed?
    assert_nil @estimate.claimed_at
  end

  test "a fresh run refuses an estimate another run has claimed and leaves that claim alone" do
    @estimate.update!(claimed_at: Time.current, updated_at: Time.current, status: "processing")
    error = assert_raises(Ai::Client::Error) do
      EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    end
    assert_equal "This estimate is already being generated.", error.message
    @estimate.reload
    assert @estimate.failed?
    assert_not_nil @estimate.claimed_at, "the refused run must not release the other run's claim"
  end

  test "a fresh run takes over an abandoned claim" do
    # The real path: a worker claimed the row an hour ago and died, then the
    # user hit Regenerate — which marks the estimate processing (bumping
    # updated_at) right before enqueuing. Only the stale claim says the old
    # run is gone, so only the claim may be trusted to judge liveness.
    @estimate.update_columns(claimed_at: 1.hour.ago, status: "processing")
    @estimate.processing!("Queued for analysis…")

    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    @estimate.reload
    assert @estimate.completed?
    assert_nil @estimate.claimed_at
  end

  test "a live run keeps refreshing its own claim as it works" do
    travel_to Time.current do
      # Five minutes of wall clock per AI call: without a heartbeat the claim
      # would go stale mid-run and a second run could take the estimate over.
      client = ClaimProbeAiClient.new(@estimate, -> { travel 5.minutes })
      EstimateGenerator.new(@estimate, client: client, batch_size: 1).call

      seen = client.claim_times.compact
      assert_operator seen.size, :>, 1, "expected several AI calls to probe"
      assert_operator seen.last, :>, seen.first,
        "the run must heartbeat claimed_at while it works, not claim once and go quiet"

      @estimate.reload
      assert @estimate.completed?
      assert_nil @estimate.claimed_at, "a finished run releases its claim"
    end
  end

  test "a reused generator instance does not release a claim it didn't take" do
    generator = EstimateGenerator.new(@estimate, client: FakeAiClient.new)
    generator.call
    # Simulate another, live run claiming the estimate after this instance finished.
    @estimate.update_columns(claimed_at: Time.current, status: "processing", updated_at: Time.current)
    assert_raises(Ai::Client::Error) { generator.call }
    assert_not_nil @estimate.reload.claimed_at, "a refused call on a reused instance must not release the other run's claim"
  end

  test "resume takes over an existing claim" do
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call
    @estimate.update!(claimed_at: 1.hour.ago, status: "processing")
    EstimateGenerator.new(@estimate, client: FakeAiClient.new).call(resume: true)
    @estimate.reload
    assert @estimate.completed?
    assert_nil @estimate.claimed_at
  end

  test "a failed run releases its claim" do
    client = FakeAiClient.new(fail_with: Ai::Client::RefusalError.new("The model declined this request."))
    assert_raises(Ai::Client::RefusalError) do
      EstimateGenerator.new(@estimate, client: client).call
    end
    assert_nil @estimate.reload.claimed_at
  end

  test "questions are harvested before the estimate is marked completed" do
    client = StatusRecordingAiClient.new(@estimate.id)
    EstimateGenerator.new(@estimate, client: client).call

    assert_equal [ "processing" ], client.statuses
    assert @estimate.reload.completed?
    assert @estimate.needs_answers?
  end

  test "a supplier quote becomes one Quoted-by line in its section" do
    client = FakeAiClient.new(analysis: FakeAiClient.quoted_analysis)
    EstimateGenerator.new(@estimate, client: client).call
    steel = @estimate.reload.sections.find_by!(name: "Structural Steel")
    quoted = steel.line_items.find { |i| i.description.start_with?("Quoted by ") }
    assert quoted, "expected a Quoted by line"
    assert_equal "Sub", quoted.item_type
    assert_equal 12_000.0, quoted.total.to_f
  end
end

class EstimateGeneratorPartialScopeTest < ActiveSupport::TestCase
  test "partial jobs cost only relevant sections plus always-on ones" do
    estimate = users(:one).estimates.create!(name: "Bathroom", estimate_template: estimate_templates(:standard))
    estimate.plans.attach(io: File.open(Rails.root.join("test/fixtures/files/plan.pdf")), filename: "plan.pdf", content_type: "application/pdf")
    analysis = FakeAiClient.new.send(:default_analysis).merge(
      "project_class" => "partial_interior_renovation",
      "relevant_sections" => [ "Structural Steel" ]
    )
    client = FakeAiClient.new(analysis: analysis)
    EstimateGenerator.new(estimate, client: client).call

    requested = client.calls.select { |c| c[:schema] == LineItemGenerator::SCHEMA }
      .flat_map { |c| c[:content].map { |b| b[:text] } }.join
    assert_includes requested, "Structural Steel"
    assert_includes requested, "Preliminaries"     # always kept
    refute_includes requested, "Solar Power System" # filtered out structurally
  end
end
