# Backfills works area/project type on the trained account's docs (they
# predate those questionnaire fields), re-ingests them so entries carry
# takeoff quantities, and prints the derived quantity norms.
#
#   bin/rails runner eval/reingest_with_quantities.rb
$stdout.sync = true

USER = User.find_by!(email_address: "david.test@example.com")
CONTEXT = {
  "Hilda (historical job)" => { "works_floor_area_m2" => "300", "project_type" => "Extension plus renovation" },
  "Constitution (historical job)" => { "works_floor_area_m2" => "400", "project_type" => "Extension plus renovation" },
  "Carberry (historical job)" => { "works_floor_area_m2" => "330", "project_type" => "Extension plus renovation" },
  "Benecia (historical job)" => { "works_floor_area_m2" => "300", "project_type" => "Raise and build under" },
  "Carson bathrooms (historical job)" => { "works_floor_area_m2" => "16", "project_type" => "Partial interior renovation (kitchen/bathrooms/rooms)" }
}.freeze

CONTEXT.each do |name, extra|
  doc = USER.training_documents.find_by!(name: name)
  if ENV["FORCE"].blank? && doc.status == "completed" &&
     PriceBookItem.from_training_doc(USER, doc.id).any? { |i| i.context.to_h["qty_kind"].present? }
    puts "#{name}: already has quantities, skipping"
    next
  end
  doc.update!(questionnaire: doc.questionnaire.to_h.merge(extra))
  puts "#{name}: re-ingesting…"
  TrainingIngestor.new(doc).call
  with_qty = PriceBookItem.from_training_doc(USER, doc.id).count { |i| i.context.to_h["qty_kind"] == "measured" }
  puts "  -> #{doc.reload.status}, #{PriceBookItem.from_training_doc(USER, doc.id).count} entries (#{with_qty} measured)"
end

puts JSON.pretty_generate(USER.reload.quantity_norms)
