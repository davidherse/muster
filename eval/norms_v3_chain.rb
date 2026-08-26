# v3 chain: personal template + hour anchoring + quantity violations.
# 1. wait for in-flight generation
# 2. synthesize + activate david.test's personal template (typical_items live)
# 3. re-derive norms (applies the supervision consistency gate)
# 4. generate huxham, hilda, rosalie sequentially
#
#   nohup bin/rails runner eval/norms_v3_chain.rb >> <log> 2>&1 &
require "yaml"

$stdout.sync = true

USER = User.find_by!(email_address: "david.test@example.com")
ACCOUNT = USER.account

while Estimate.uncached { Estimate.where(status: "processing").exists? }
  puts "waiting for in-flight generation… (#{Time.current.strftime('%H:%M')})"
  sleep 120
  ActiveRecord::Base.connection_pool.release_connection
end

puts "synthesizing personal template…"
template = TemplateSynthesizer.new(ACCOUNT).call
abort("no template synthesized") unless template
template.activate!
puts "  -> ACTIVE: #{template.name} (#{template.sections.size} sections)"

QuantityNorms.derive!(ACCOUNT)
sup = ACCOUNT.reload.quantity_norms.dig("groups", "whole", "supervision_hours_per_week")
puts "whole-house supervision norm after gate: #{sup.inspect}"

CONFIG = YAML.load_file(Rails.root.join("eval/projects.yml"))
NAMES = { "hilda" => "Hilda St — Enoggera", "huxham" => "17 Huxham Tce — Auchenflower", "rosalie" => "77 Rosalie St" }.freeze

%w[huxham hilda rosalie].each do |job|
  cfg = CONFIG.fetch(job)
  estimate = USER.estimates.create!(name: "#{NAMES.fetch(job)} (norms-v3)",
    prompt: cfg["prompt"], questionnaire: cfg["questionnaire"])
  Array(cfg["plan"]).each do |path|
    estimate.plans.attach(io: File.open(path), filename: File.basename(path), content_type: "application/pdf")
  end
  puts "#{job} v3: generating estimate #{estimate.id}…"
  begin
    EstimateGenerator.new(estimate).call
    puts "  -> #{estimate.reload.status}, #{estimate.line_items.count} items"
  rescue StandardError => e
    puts "  -> FAILED: #{e.message.to_s.truncate(200)}"
  end
end
puts "v3 chain done"
