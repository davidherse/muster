# Answers the three previously-skipped Huxham questions from the actuals and
# re-costs their sections — completing the full 8/8 answered comparison.
$stdout.sync = true

e = Estimate.find(324)
abort("estimate busy") if e.processing?

ANSWERS = {
  /air-?con|ducted|solar/i =>
    "No ducted - each room keeps wall-mounted splits: one new Mitsubishi split to the Study, and the existing Bed 1-3, Rumpus and Dining units decommissioned, serviced and reinstalled or relocated. Solar is a new 11.88kW system with one battery, existing panels removed.",
  /rock|bored piers|footing schedule/i =>
    "Soil came back better than the engineering allowed - about 20 bored piers were credited out as not required; footings are strip footings between posts (~135 lm) plus the garage slab, roughly 80 m3 of concrete all up, no rock socketing.",
  /access|crane and truck|hand/i =>
    "Crane access is available from the street - cranes were used for the trusses, roof sheets and the pool shell - but allow substantial labourer time for moving materials around the steep side (about 200 hours of site labour)."
}.freeze

skipped = Array(e.open_questions).select { |q| q["skipped"] }
abort("expected 3 skipped, got #{skipped.size}") unless skipped.size == 3

clarified = skipped.map do |q|
  answer = ANSWERS.find { |pat, _| q["question"] =~ pat }&.last
  abort("no answer matched: #{q['question'][0, 80]}") unless answer
  q.slice("question").merge("answer" => answer)
end

e.update!(clarifications: Array(e.clarifications) + clarified, open_questions: [])
affected = e.sections.where(name: skipped.flat_map { |q| Array(q["sections"]) }.uniq)
puts "bound 3 answers; re-costing #{affected.count} sections: #{affected.map(&:name).join(', ')}"
e.update!(costed_sections: e.costed_sections - affected.map(&:name))
affected.destroy_all
e.update!(status: "processing", error_message: nil, progress_note: "Improving with the final answers…")
EstimateGenerator.new(e).call(resume: true)
puts "  -> #{e.reload.status}, #{e.line_items.count} items, total #{e.line_items.sum { |i| i.total.to_f }.round}"
puts "remaining answers done"
