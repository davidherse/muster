# Loads the Built Homes historical training documents into a user's account
# from eval/training_docs_metadata.json — the scripted equivalent of uploading
# each through the wizard. Ingests sequentially (each doc is several AI calls;
# expect ~10 min and a few dollars per large costing).
#
#   USER_EMAIL=david@... DIR=/path/to/costings bin/rails runner eval/load_training_docs.rb
#
# Resume-safe: docs already completed for this user are skipped.
require "json"

$stdout.sync = true

user = User.find_by!(email_address: ENV.fetch("USER_EMAIL"))
dir = ENV.fetch("DIR")
docs = JSON.parse(File.read(Rails.root.join("eval/training_docs_metadata.json")))

CONTENT_TYPES = {
  ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".xls" => "application/vnd.ms-excel",
  ".csv" => "text/csv",
  ".pdf" => "application/pdf"
}.freeze

docs.each do |meta|
  existing = user.training_documents.find_by(name: meta["name"])
  if existing&.status == "completed"
    puts "#{meta['name']}: already ingested, skipping"
    next
  end

  path = File.join(dir, meta["file"])
  abort("missing file: #{path}") unless File.exist?(path)

  doc = existing || user.training_documents.create!(
    name: meta["name"],
    priced_on: meta["priced_on"].presence && Date.parse(meta["priced_on"]),
    description: meta["description"],
    questionnaire: meta["questionnaire"] || {}
  )
  doc.files.attach(io: File.open(path), filename: meta["file"],
    content_type: CONTENT_TYPES.fetch(File.extname(meta["file"]).downcase, "application/octet-stream")) unless doc.files.attached?

  puts "#{meta['name']}: ingesting…"
  begin
    TrainingIngestor.new(doc).call
    puts "  -> #{doc.reload.status}, #{PriceBookItem.from_training_doc(user, doc.id).count} book entries"
  rescue StandardError => e
    puts "  -> FAILED: #{e.message.to_s.truncate(200)} (re-run to resume)"
  end
end

norms = user.reload.quantity_norms
puts
puts "book total: #{PriceBookItem.for_user(user).count} entries"
puts "norms derived: #{norms&.dig('derived_at') || 'none'}"
puts "NEXT: the user signs in and agrees the proposed template at /onboarding/template"
puts "load done"
