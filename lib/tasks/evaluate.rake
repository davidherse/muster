require "csv"

# Runs the real AI pipeline against historical plans and scores the result
# against what the jobs actually cost.
#
#   bin/rails "estimator:evaluate[hilda]"       # one project
#   bin/rails estimator:evaluate                # every project in eval/projects.yml
#
# Requires ANTHROPIC_API_KEY. Each project takes several minutes and costs real
# API usage (the full plan PDF is analysed).
namespace :estimator do
  desc "Evaluate estimator accuracy against historical actuals"
  task :evaluate, [ :project ] => :environment do |_t, args|
    config = YAML.load_file(Rails.root.join("eval/projects.yml"))
    names = args[:project].present? ? [ args[:project] ] : config.keys
    results = []

    names.each do |name|
      entry = config.fetch(name) { abort "Unknown project #{name}. Available: #{config.keys.join(', ')}" }
      plan_path = entry.fetch("plan")
      abort "Plan not found: #{plan_path}" unless File.exist?(plan_path)

      puts "\n=== #{name} ==="
      puts "Plan: #{File.basename(plan_path)} (#{(File.size(plan_path) / 1.megabyte.to_f).round(1)} MB)"

      user = User.find_or_create_by!(email_address: "eval@example.com") do |u|
        u.name = "Evaluator"
        u.password = SecureRandom.hex(12)
        u.activated_at = Time.current
      end

      estimate = user.estimates.create!(
        name: "EVAL #{name} #{Time.current.strftime('%Y%m%d%H%M')}",
        prompt: entry["prompt"],
        estimate_template: EstimateTemplate.default
      )
      estimate.plan.attach(io: File.open(plan_path), filename: File.basename(plan_path), content_type: "application/pdf")

      started = Time.current
      begin
        EstimateGenerator.new(estimate).call
      rescue StandardError => e
        puts "  FAILED: #{estimate.reload.error_message || e.message}"
        next
      end
      estimate.reload
      puts "  Generated #{estimate.sections.count} sections, #{estimate.line_items.count} line items in #{(Time.current - started).round}s"

      results << score(name, estimate, Rails.root.join(entry.fetch("baseline")), entry.fetch("escalation_factor", 1.0).to_f)
    end

    if results.any?
      puts "\n#{'=' * 64}\nSUMMARY"
      results.each { |r| puts format("  %-14s AI $%12s  actual $%12s  error %s", r[:name], comma(r[:ai]), comma(r[:baseline]), r[:error]) }
      errors = results.filter_map { |r| r[:error_pct]&.abs }
      puts format("  Mean absolute total error: %.1f%%", errors.sum / errors.size) if errors.any?
    end
  end

  def score(name, estimate, baseline_path, factor = 1.0)
    rows = CSV.read(baseline_path, headers: true)
    total_row = rows.find { |r| r["category"] == "__TOTAL__" }
    actual = total_row["actual_total"].presence&.to_f
    human = total_row["human_estimate_total"].presence&.to_f
    baseline = actual || human
    baseline_label = actual ? "actual" : "human estimate"

    # The AI estimates in current (2026) dollars; the baseline is in the job's
    # cost-base dollars. Deflate the AI figure for a like-for-like comparison.
    ai = estimate.total.to_f / factor
    error_pct = baseline&.positive? ? ((ai - baseline) / baseline * 100) : nil

    puts format("  AI estimate:      $%s in 2026 dollars", comma(estimate.total))
    puts format("  AI (job-year $):  $%s  (range $%s – $%s, deflated /%.2f)", comma(ai), comma(estimate.total_low.to_f / factor), comma(estimate.total_high.to_f / factor), factor)
    puts format("  Human estimate:   $%s", comma(human)) if human
    puts format("  Actual cost:      $%s", comma(actual)) if actual
    puts format("  Error vs %-15s %+.1f%%", "#{baseline_label}:", error_pct) if error_pct
    if baseline && estimate.total_low && estimate.total_high
      inside = baseline.between?(estimate.total_low.to_f / factor, estimate.total_high.to_f / factor)
      puts "  #{baseline_label.capitalize} within AI range: #{inside ? 'YES' : 'NO'}"
    end

    puts "  Largest AI sections:"
    estimate.sections.sort_by { |s| -s.subtotal }.first(8).each do |s|
      puts format("    %-48s $%s", s.name.truncate(46), comma(s.subtotal))
    end

    { name: name, ai: ai, baseline: baseline, error: error_pct ? format("%+.1f%%", error_pct) : "n/a", error_pct: error_pct }
  end

  def comma(value)
    return "?" if value.nil?
    value.to_f.round.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\1,')
  end
end
