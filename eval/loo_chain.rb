# Leave-one-out harness: estimate each job with every OTHER job's data in
# the book (the job's own upload parked for the duration of its run). Seven
# genuinely-unseen measurements per config instead of two.
#
#   nohup bin/rails runner eval/loo_chain.rb >> <log> 2>&1 &
#
# Resume-safe: jobs with an existing completed "(loo-v6)" estimate are
# skipped; parked entries are restored even on failure.
require "yaml"

$stdout.sync = true

USER = User.find_by!(email_address: "david.test@example.com")
TAG = ENV.fetch("TAG", "loo-v6")
CONFIG = YAML.load_file(Rails.root.join("eval/projects.yml"))
NAMES = {
  "hilda" => "Hilda St — Enoggera", "constitution" => "Constitution St — Windsor",
  "benecia" => "Benecia — Wavell Heights", "carberry" => "Carberry St — Grange",
  "carson" => "6 Carson — Bathrooms", "huxham" => "17 Huxham Tce — Auchenflower",
  "rosalie" => "77 Rosalie St"
}.freeze
DOCS = {
  "hilda" => "Hilda (historical job)", "constitution" => "Constitution (historical job)",
  "carberry" => "Carberry (historical job)", "benecia" => "Benecia (historical job)",
  "carson" => "Carson bathrooms (historical job)", "rosalie" => "Rosalie (historical job)",
  "huxham" => "Huxham (historical job)"
}.freeze

while Estimate.uncached { Estimate.where(status: "processing").exists? }
  puts "waiting for in-flight work… (#{Time.current.strftime('%H:%M')})"
  sleep 120
  ActiveRecord::Base.connection_pool.release_connection
end

# Safety: restore anything a crashed prior run left parked.
restored = PriceBookItem.where(user: USER, source_kind: "parked").update_all(source_kind: "user")
puts "restored #{restored} parked entries from a prior run" if restored.positive?

# The 7th doc: Huxham has never been ingested.
unless USER.training_documents.exists?(name: DOCS["huxham"])
  doc = USER.training_documents.create!(
    name: DOCS["huxham"], priced_on: Date.new(2026, 5, 1),
    description: "Raise and build-under of a Queenslander on a steep block at 17 Huxham Tce, with rear deck and pool.",
    questionnaire: { "works_floor_area_m2" => "350", "duration_months" => "14",
                     "project_type" => "Raise and build under" }
  )
  path = "/Users/davidherse/Dropbox/Built Homes/esitmates/17 Huxham - J1187-JobCostingsActual-20260703050859.xlsx"
  doc.files.attach(io: File.open(path), filename: File.basename(path),
    content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  puts "ingesting Huxham costing…"
  TrainingIngestor.new(doc).call
  puts "  -> #{doc.reload.status}, #{PriceBookItem.from_training_doc(USER, doc.id).count} entries"
end

NAMES.each_key do |job|
  if Estimate.exists?(user: USER, status: "completed") &&
     Estimate.where(user: USER, status: "completed").where("name LIKE ?", "%(#{TAG})").any? { |e| e.name.start_with?(NAMES[job]) }
    puts "#{job}: #{TAG} estimate exists, skipping"
    next
  end

  doc = USER.training_documents.find_by!(name: DOCS.fetch(job))
  cfg = CONFIG.fetch(job)
  parked = PriceBookItem.from_training_doc(USER, doc.id)
  puts "#{job}: parking #{parked.count} own-doc entries…"
  PriceBookItem.where(id: parked.map(&:id)).update_all(source_kind: "parked")
  QuantityNorms.derive!(USER)

  begin
    estimate = USER.estimates.create!(
      name: "#{NAMES.fetch(job)} (#{TAG})",
      prompt: cfg["prompt"], questionnaire: cfg["questionnaire"],
      estimate_template: EstimateTemplate.global.active.order(:id).first
    )
    Array(cfg["plan"]).each do |path|
      estimate.plans.attach(io: File.open(path), filename: File.basename(path), content_type: "application/pdf")
    end
    puts "#{job}: generating estimate #{estimate.id}…"
    EstimateGenerator.new(estimate).call
    puts "  -> #{estimate.reload.status}, #{estimate.line_items.count} items"
  rescue StandardError => e
    puts "  -> FAILED: #{e.message.to_s.truncate(200)}"
  ensure
    PriceBookItem.where(user: USER, source_kind: "parked").update_all(source_kind: "user")
    QuantityNorms.derive!(USER)
  end
end
puts "loo chain done"
