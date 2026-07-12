# Scores completed estimates against ground-truth takeoffs.
#
#   JOB=carson  bin/rails runner eval/run_quantity_eval.rb          # one job
#   JOB=all     bin/rails runner eval/run_quantity_eval.rb          # all with ground truth
#   ESTIMATE=123 JOB=carson bin/rails runner eval/run_quantity_eval.rb  # score a specific estimate
#
# Default estimate per job: the most recent completed one whose name matches
# the job's grid-base run. Results land in eval/results/quantity/<job>.json.
require_relative "quantity_scorer"

$stdout.sync = true

NAME_PATTERNS = {
  "hilda" => "Hilda St%",
  "constitution" => "Constitution St%",
  "benecia" => "Benecia%",
  "carberry" => "Carberry St%",
  "carson" => "6 Carson%",
  "huxham" => "17 Huxham%",
  "rosalie" => "77 Rosalie%"
}.freeze
OUT_DIR = Rails.root.join("eval/results/quantity")

def estimate_for(job)
  return Estimate.find(ENV["ESTIMATE"]) if ENV["ESTIMATE"].present?
  Estimate.where(status: "completed")
          .where("name LIKE ?", NAME_PATTERNS.fetch(job))
          .order(:created_at).last or abort("no completed estimate found for #{job}")
end

jobs =
  if ENV["JOB"] == "all"
    Dir[Rails.root.join("eval/ground_truth/*.json")].map { |f| File.basename(f, ".json") }
  else
    [ ENV.fetch("JOB") ]
  end

rows = jobs.map do |job|
  gt_path = Rails.root.join("eval/ground_truth/#{job}.json")
  abort("no ground truth for #{job} — run extract_ground_truth.rb first") unless File.exist?(gt_path)
  gt = JSON.parse(File.read(gt_path))
  estimate = estimate_for(job)
  puts "#{job}: scoring estimate #{estimate.id} (#{estimate.name})…"
  result = QuantityScorer.new(gt, estimate).call
  FileUtils.mkdir_p(OUT_DIR)
  File.write(OUT_DIR.join("#{job}.json"), JSON.pretty_generate(result))
  result
end

puts
puts format("%-14s %8s %8s %10s %10s %8s %12s %12s", "job", "gt items", "est", "recall%", "precis%", "sect%", "qty medAPE%", "qty<=20%%")
rows.each do |r|
  puts format("%-14s %8d %8d %10s %10s %8s %12s %12s",
    r[:job], r[:gt_items], r[:est_items], r[:item_recall_pct], r[:item_precision_pct],
    r[:section_coverage_pct], r[:qty_median_ape_pct] || "-", r[:qty_within_20_pct] || "-")
end
