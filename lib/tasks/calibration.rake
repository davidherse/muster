require "csv"

# Compares the assessor's stated confidence/variance against measured error
# for every completed EVAL estimate that has an assessment:
#   bin/rails estimator:calibration
namespace :estimator do
  desc "Assessor calibration: stated variance vs actual error"
  task calibration: :environment do
    config = YAML.load_file(Rails.root.join("eval/projects.yml"))
    rows = []
    Estimate.where("name LIKE 'EVAL %'").where(status: "completed").find_each do |e|
      proj = config.keys.find { |k| e.name.match?(/EVAL #{k}\b/) }
      next unless proj
      next if e.assessment.blank? || e.assessment["confidence"].blank?

      entry = config[proj]
      factor = entry.fetch("escalation_factor", 1.0).to_f
      baseline = nil
      CSV.read(Rails.root.join(entry.fetch("baseline")), headers: true).each do |r|
        baseline = (r["actual_total"].presence || r["human_estimate_total"]).to_f if r["category"] == "__TOTAL__"
      end
      next unless baseline&.positive?

      error_pct = ((e.total.to_f / factor) - baseline) / baseline * 100
      stated = e.assessment["expected_variance_pct"].to_f
      rows << {
        name: e.name, proj: proj, confidence: e.assessment["confidence"],
        stated: stated, error: error_pct, covered: error_pct.abs <= stated
      }
    end

    if rows.empty?
      puts "No assessed EVAL estimates yet."
    else
      puts format("%-38s %-8s %10s %10s %9s", "estimate", "conf", "stated ±%", "error %", "covered?")
      rows.sort_by { |r| r[:name] }.each do |r|
        puts format("%-38s %-8s %10.1f %+10.1f %9s", r[:name][0, 36], r[:confidence], r[:stated], r[:error], r[:covered] ? "yes" : "NO")
      end
      covered = rows.count { |r| r[:covered] }
      puts format("Coverage: %d/%d estimates within stated variance", covered, rows.size)
      %w[high medium low].each do |conf|
        sub = rows.select { |r| r[:confidence] == conf }
        next if sub.empty?
        puts format("  %-7s n=%d mean abs error %.1f%% vs mean stated ±%.1f%%",
                    conf, sub.size, sub.sum { |r| r[:error].abs } / sub.size, sub.sum { |r| r[:stated] } / sub.size)
      end
    end
  end
end
