# v6: crew-day labour framing + Rosalie's costing added to the book
# (data-scaling test — Huxham remains unseen). Default template pinned to
# match the v2 champion config.
#   nohup bin/rails runner eval/norms_v6_chain.rb >> <log> 2>&1 &
require "yaml"

$stdout.sync = true

USER = User.find_by!(email_address: "david.test@example.com")

while Estimate.uncached { Estimate.where(status: "processing").exists? } ||
      system("pgrep -f norms_v5_chain > /dev/null 2>&1")
  puts "waiting for in-flight work… (#{Time.current.strftime('%H:%M')})"
  sleep 120
  ActiveRecord::Base.connection_pool.release_connection
end

unless USER.training_documents.exists?(name: "Rosalie (historical job)")
  doc = USER.training_documents.create!(
    name: "Rosalie (historical job)",
    priced_on: Date.new(2025, 6, 1),
    description: "Whole-house renovation of a large Queenslander at 77 Rosalie St.",
    questionnaire: { "works_floor_area_m2" => "314", "duration_months" => "12",
                     "project_type" => "Whole-house renovation" }
  )
  path = "/Users/davidherse/Dropbox/Built Homes/esitmates/77 Rosalie - J1162-JobCostingsActual-20260703050947.xlsx"
  doc.files.attach(io: File.open(path), filename: File.basename(path),
    content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  puts "ingesting Rosalie costing…"
  TrainingIngestor.new(doc).call
  measured = PriceBookItem.from_training_doc(USER, doc.id).count { |i| i.context.to_h["qty_kind"] == "measured" }
  puts "  -> #{doc.reload.status}, #{measured} measured takeoffs"
end

cfg = YAML.load_file(Rails.root.join("eval/projects.yml")).fetch("huxham")
estimate = USER.estimates.create!(
  name: "17 Huxham Tce — Auchenflower (norms-v6)",
  prompt: cfg["prompt"], questionnaire: cfg["questionnaire"],
  estimate_template: EstimateTemplate.global.active.order(:id).first
)
Array(cfg["plan"]).each do |path|
  estimate.plans.attach(io: File.open(path), filename: File.basename(path), content_type: "application/pdf")
end
puts "huxham v6: generating estimate #{estimate.id}…"
EstimateGenerator.new(estimate).call
puts "  -> #{estimate.reload.status}, #{estimate.line_items.count} items"
puts "v6 chain done"
