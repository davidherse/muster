# Sequential chain for the norms-v2 whole-house experiment:
# 1. wait for any in-flight generation to finish (book swaps mid-run corrupt it)
# 2. re-ingest the four whole-house docs with the quoted-quantity rule
# 3. regenerate Huxham on the corrected norms/book
#
#   nohup bin/rails runner eval/norms_v2_chain.rb >> <log> 2>&1 &
$stdout.sync = true

USER = User.find_by!(email_address: "david.test@example.com")

while Estimate.where(status: "processing").exists?
  puts "waiting for in-flight generation… (#{Time.current.strftime('%H:%M')})"
  sleep 120
end

%w[Hilda Constitution Carberry Benecia].each do |short|
  doc = USER.training_documents.find_by!(name: "#{short} (historical job)")
  puts "#{short}: re-ingesting with quoted-quantity rule…"
  TrainingIngestor.new(doc).call
  measured = PriceBookItem.from_training_doc(USER, doc.id).count { |i| i.context.to_h["qty_kind"] == "measured" }
  puts "  -> #{doc.reload.status}, #{measured} measured"
end

norms = USER.reload.quantity_norms
puts "whole-house supervision norm: #{norms.dig('groups', 'whole', 'supervision_hours_per_week').inspect}"

require "yaml"
cfg = YAML.load_file(Rails.root.join("eval/projects.yml")).fetch("huxham")
estimate = USER.estimates.create!(name: "17 Huxham Tce — Auchenflower (norms-v2)",
  prompt: cfg["prompt"], questionnaire: cfg["questionnaire"])
Array(cfg["plan"]).each do |path|
  estimate.plans.attach(io: File.open(path), filename: File.basename(path), content_type: "application/pdf")
end
puts "huxham v2: generating estimate #{estimate.id}…"
EstimateGenerator.new(estimate).call
puts "  -> #{estimate.reload.status}, #{estimate.line_items.count} items"
puts "chain done: huxham v2 estimate #{estimate.id}"
