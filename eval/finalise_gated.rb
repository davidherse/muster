# Finalises every gated estimate: answers pending questions from that job's
# actuals (oracle), improves, and — with the one-round harvest rule — each
# finishes clean as Completed. Unanswerable questions are skipped.
#
#   nohup bin/rails runner eval/finalise_gated.rb >> <log> 2>&1 &
require "json"

$stdout.sync = true

JOB_PATTERNS = {
  "hilda" => /Hilda/i, "constitution" => /Constitution/i, "benecia" => /Benecia/i,
  "carberry" => /Carberry/i, "carson" => /Carson/i, "huxham" => /Huxham/i, "rosalie" => /Rosalie/i
}.freeze

ANSWER_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: %w[answers],
  properties: {
    answers: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: %w[id known answer],
        properties: {
          id: { type: "integer" },
          known: { type: "boolean" },
          answer: { type: "string" }
        }
      }
    }
  }
}.freeze

def oracle_answers(job, questions, client)
  gt = JSON.parse(File.read(Rails.root.join("eval/ground_truth/#{job}.json")))
  items_text = gt["items"].map { |i| "#{i['section']} | #{i['description']} | #{i['quantity']} #{i['uom']}" }.join("\n")
  q_text = questions.map { |q| "#{q['id']}. #{q['question']}" }.join("\n")
  client.complete_json(
    system: [ { type: "text", text: "You are the builder who ran this job, answering an estimator's clarifying questions from your as-built costing records. Answer ONLY what the records support; where they genuinely don't answer, set known=false rather than guessing." } ],
    content: [ { type: "text", text: "THE JOB'S ACTUAL COSTING LINES (section | work | quantity):\n#{items_text}\n\nQUESTIONS:\n#{q_text}" } ],
    schema: ANSWER_SCHEMA
  )["answers"]
end

gated = Estimate.where(status: "completed").select(&:needs_answers?)
puts "#{gated.size} gated estimates: #{gated.map(&:id).join(', ')}"

gated.each do |e|
  while Estimate.uncached { Estimate.where(status: "processing").exists? }
    puts "waiting for in-flight run… (#{Time.current.strftime('%H:%M')})"
    sleep 120
    ActiveRecord::Base.connection_pool.release_connection
  end
  e.reload
  next unless e.needs_answers?

  job = JOB_PATTERNS.find { |_, pat| e.name =~ pat }&.first
  unless job
    puts "#{e.id}: no job match for '#{e.name}', leaving alone"
    next
  end

  questions = Array(e.open_questions).reject { |q| q["skipped"] }
  client = Ai::Client.new
  answers = oracle_answers(job, questions, client)
  by_id = answers.to_h { |a| [ a["id"], a ] }
  answered, skipped = questions.partition { |q| by_id[q["id"]]&.dig("known") }
  puts "#{e.id} (#{job}): #{answered.size} answered, #{skipped.size} skipped"

  e.update!(
    clarifications: Array(e.clarifications) + answered.map { |q| q.slice("question").merge("answer" => by_id[q["id"]]["answer"]) },
    open_questions: Array(e.open_questions).select { |q| q["skipped"] } + skipped.map { |q| q.merge("skipped" => true) }
  )
  next if answered.empty?

  affected = e.sections.where(name: answered.flat_map { |q| Array(q["sections"]) }.uniq)
  puts "  re-costing #{affected.count} sections…"
  e.update!(costed_sections: e.costed_sections - affected.map(&:name))
  affected.destroy_all
  e.update!(status: "processing", error_message: nil, progress_note: "Improving with answers…")
  begin
    EstimateGenerator.new(e).call(resume: true)
    puts "  -> #{e.reload.status}, needs_answers now: #{e.needs_answers?}"
  rescue StandardError => ex
    puts "  -> FAILED: #{ex.message.to_s.truncate(150)}"
  end
end
puts "finalise done — gated remaining: #{Estimate.where(status: 'completed').select(&:needs_answers?).map(&:id).inspect}"
