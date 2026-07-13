# Generates estimates under the trained account (user book + quantity norms
# + builder templates) for the norms experiment, sequentially.
#
#   JOBS=carson,huxham,hilda TAG=norms-v1 bin/rails runner eval/run_norms_fleet.rb
require "yaml"

$stdout.sync = true

USER = User.find_by!(email_address: "david.test@example.com")
CONFIG = YAML.load_file(Rails.root.join("eval/projects.yml"))
NAMES = {
  "hilda" => "Hilda St — Enoggera",
  "constitution" => "Constitution St — Windsor",
  "benecia" => "Benecia — Wavell Heights",
  "carberry" => "Carberry St — Grange",
  "carson" => "6 Carson — Bathrooms",
  "huxham" => "17 Huxham Tce — Auchenflower",
  "rosalie" => "77 Rosalie St"
}.freeze

tag = ENV.fetch("TAG", "norms-v1")
jobs = ENV.fetch("JOBS").split(",").map(&:strip)

jobs.each do |job|
  cfg = CONFIG.fetch(job)
  estimate = USER.estimates.create!(
    name: "#{NAMES.fetch(job)} (#{tag})",
    prompt: cfg["prompt"],
    questionnaire: cfg["questionnaire"],
    # TEMPLATE=default pins the shared template, isolating template effects
    # from prompt/book effects across experiment cells.
    estimate_template: ENV["TEMPLATE"] == "default" ? EstimateTemplate.global.active.order(:id).first : nil
  )
  Array(cfg["plan"]).each do |path|
    estimate.plans.attach(io: File.open(path), filename: File.basename(path), content_type: "application/pdf")
  end
  puts "#{job}: generating estimate #{estimate.id}…"
  begin
    EstimateGenerator.new(estimate).call
    puts "  -> #{estimate.reload.status}, #{estimate.line_items.count} items, total #{estimate.line_items.sum { |i| i.total.to_f }.round}"
  rescue StandardError => e
    puts "  -> FAILED: #{e.message.to_s.truncate(200)}"
  end
end
puts "fleet done"
