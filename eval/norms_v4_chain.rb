# Waits for in-flight generation, then runs Huxham on the derive-not-copy
# hour anchoring prompt.
#   nohup bin/rails runner eval/norms_v4_chain.rb >> <log> 2>&1 &
require "yaml"

$stdout.sync = true

USER = User.find_by!(email_address: "david.test@example.com")

while Estimate.uncached { Estimate.where(status: "processing").exists? } ||
      system("pgrep -f norms_v3_chain > /dev/null")
  puts "waiting for v3 chain… (#{Time.current.strftime('%H:%M')})"
  sleep 120
  ActiveRecord::Base.connection_pool.release_connection
end

cfg = YAML.load_file(Rails.root.join("eval/projects.yml")).fetch("huxham")
estimate = USER.estimates.create!(name: "17 Huxham Tce — Auchenflower (norms-v4)",
  prompt: cfg["prompt"], questionnaire: cfg["questionnaire"])
Array(cfg["plan"]).each do |path|
  estimate.plans.attach(io: File.open(path), filename: File.basename(path), content_type: "application/pdf")
end
puts "huxham v4: generating estimate #{estimate.id}…"
EstimateGenerator.new(estimate).call
puts "  -> #{estimate.reload.status}, #{estimate.line_items.count} items"
puts "v4 chain done"
