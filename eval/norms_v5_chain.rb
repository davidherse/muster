# v5: fresh runs with the framing-extent takeoff + derive-not-copy anchoring
# + component-breakdown matching. Waits for in-flight work first.
#   nohup bin/rails runner eval/norms_v5_chain.rb >> <log> 2>&1 &
require "yaml"

$stdout.sync = true

USER = User.find_by!(email_address: "david.test@example.com")

while Estimate.uncached { Estimate.where(status: "processing").exists? } ||
      system("pgrep -f 'v4_resume|Estimate.find\\(315\\)' > /dev/null 2>&1")
  puts "waiting for in-flight work… (#{Time.current.strftime('%H:%M')})"
  sleep 120
  ActiveRecord::Base.connection_pool.release_connection
end

CONFIG = YAML.load_file(Rails.root.join("eval/projects.yml"))
NAMES = { "huxham" => "17 Huxham Tce — Auchenflower", "rosalie" => "77 Rosalie St" }.freeze

%w[huxham rosalie].each do |job|
  cfg = CONFIG.fetch(job)
  estimate = USER.estimates.create!(name: "#{NAMES.fetch(job)} (norms-v5)",
    prompt: cfg["prompt"], questionnaire: cfg["questionnaire"])
  Array(cfg["plan"]).each do |path|
    estimate.plans.attach(io: File.open(path), filename: File.basename(path), content_type: "application/pdf")
  end
  puts "#{job} v5: generating estimate #{estimate.id}…"
  begin
    EstimateGenerator.new(estimate).call
    puts "  -> #{estimate.reload.status}, #{estimate.line_items.count} items"
  rescue StandardError => e
    puts "  -> FAILED: #{e.message.to_s.truncate(200)}"
  end
end
puts "v5 chain done"
