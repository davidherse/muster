require "csv"

# Section-level over/under analysis for the latest EVAL run of a project:
#   bin/rails "estimator:autopsy[huxham]"
# Buckets AI sections and baseline categories into canonical trade groups so
# differing section names compare cleanly, all in job-year dollars.
namespace :estimator do
  def bucket_for(name) = TradeBucket.for(name)

  desc "Bucketed over/under analysis for a project's latest EVAL estimate"
  task :autopsy, [ :project ] => :environment do |_t, args|
    name = args[:project] or abort "usage: estimator:autopsy[project]"
    config = YAML.load_file(Rails.root.join("eval/projects.yml")).fetch(name)
    factor = config.fetch("escalation_factor", 1.0).to_f

    estimate = Estimate.where("name LIKE ?", "EVAL #{name}%").where(status: "completed").order(:id).last
    abort "no completed EVAL estimate for #{name}" unless estimate

    ai = Hash.new(0.0)
    estimate.sections.includes(:line_items).each do |s|
      ai[bucket_for(s.name)] += s.subtotal.to_f / factor
    end

    base = Hash.new(0.0)
    baseline_total = nil
    human_total = nil
    CSV.read(Rails.root.join(config.fetch("baseline")), headers: true).each do |r|
      if r["category"] == "__TOTAL__"
        baseline_total = r["actual_total"].presence&.to_f
        human_total = r["human_estimate_total"].presence&.to_f
        next
      end
      value = (r["actual_total"].presence || r["human_estimate_total"]).to_f
      base[bucket_for(r["category"])] += value
    end
    baseline_total ||= base.values.sum

    puts "#{name} — #{estimate.name} (job-year $, AI deflated /#{factor})"
    puts format("%-22s %12s %12s %12s", "bucket", "AI", "baseline", "gap")
    (ai.keys | base.keys).sort_by { |b| -(ai[b] - base[b]).abs }.each do |b|
      puts format("%-22s %12d %12d %+12d", b, ai[b], base[b], ai[b] - base[b])
    end
    ai_total = ai.values.sum
    puts format("%-22s %12d %12d %+12d  (%+.1f%%)", "TOTAL", ai_total, baseline_total, ai_total - baseline_total,
                (ai_total - baseline_total) / baseline_total * 100)
    puts format("vs human estimate: %+.1f%%", (ai_total - human_total) / human_total * 100) if human_total&.positive?
  end
end
