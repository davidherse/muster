# Re-applies David's Huxham answers (dropped by a stale-schema web process)
# to estimate 324 and re-runs the improve cycle from a fresh process.
$stdout.sync = true

ESTIMATE_ID = 324

while Estimate.uncached { Estimate.where(status: "processing").exists? }
  puts "waiting for in-flight run… (#{Time.current.strftime('%H:%M')})"
  sleep 120
  ActiveRecord::Base.connection_pool.release_connection
end

e = Estimate.find(ESTIMATE_ID)
questions = Array(e.open_questions)
abort("expected 8 questions, got #{questions.size}") unless questions.size == 8

ANSWERS = {
  1 => "Builder carries the whole pool, but it's a precast Plungie Max 6x3 shell craned in - shell ~$22k plus freight, crane, eco equipment package (~$3k), plumbing and electrical allowances, coping/waterline tiling (~27 m2), and the glass fence (~$8k) - not an in-situ build.",
  2 => "Minor only - an 800 mm high wall parallel to the rear boundary (~$10k) with ~28 lm of concrete footings; no full-height engineered walls.",
  5 => "The frame was largely sound - about 24 hours of plumb, pack and straighten plus roof tie-down; no significant rot replacement. The roof sheeting itself was fully replaced.",
  6 => "All external windows and doors replaced with new aluminium per the schedule, flyscreens throughout with stainless where code requires plus a stainless barrier screen, custom window hoods, and the alfresco stacker supplied and installed by the window company.",
  7 => "About right - stone benchtops landed ~$33k, and cabinetry was a full-house package (kitchen, island, walk-in pantry, drinks nook, vanities, robes, panelling)."
}.freeze

answered, skipped = questions.partition { |q| ANSWERS.key?(q["id"]) }
e.update!(
  clarifications: answered.map { |q| q.slice("question").merge("answer" => ANSWERS.fetch(q["id"])) },
  open_questions: skipped.map { |q| q.merge("skipped" => true) }
)
puts "bound #{e.clarifications.size} answers, #{skipped.size} skipped"

affected = e.sections.where(name: answered.flat_map { |q| Array(q["sections"]) }.uniq)
puts "re-costing #{affected.count} sections: #{affected.map(&:name).join(', ')}"
e.update!(costed_sections: e.costed_sections - affected.map(&:name))
affected.destroy_all
e.update!(status: "processing", error_message: nil, progress_note: "Improving with answers…")
EstimateGenerator.new(e).call(resume: true)
puts "  -> #{e.reload.status}, #{e.line_items.count} items, total #{e.line_items.sum { |i| i.total.to_f }.round}"
puts "answers applied done"
