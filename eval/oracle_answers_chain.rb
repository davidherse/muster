# Answers every gated LOO estimate's questions from that job's ACTUALS (the
# ground-truth costing), improves it, and re-scores — measuring the question
# loop's value across the whole board. Questions the actuals can't answer are
# skipped, mirroring an honest client.
#
#   nohup bin/rails runner eval/oracle_answers_chain.rb >> <log> 2>&1 &
require_relative "quantity_scorer"
require "csv"

$stdout.sync = true

JOBS = {
  "hilda" => 319, "constitution" => 320, "benecia" => 321,
  "carberry" => 322, "carson" => 323, "rosalie" => 325
}.freeze
FACTORS = { "hilda" => 1.29, "constitution" => 1.1, "benecia" => 1.17,
            "carberry" => 1.04, "carson" => 1.0, "rosalie" => 1.07 }.freeze

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
          known: { type: "boolean", description: "false when the actuals genuinely do not answer the question — do not guess" },
          answer: { type: "string", description: "One-to-two sentence answer AS THE BUILDER would give it, grounded in the actuals; empty string when known=false" }
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
    system: [ { type: "text", text: <<~PROMPT } ],
      You are the builder who ran this job, answering an estimator's clarifying
      questions from your own as-built costing records. Answer ONLY what the
      records support — scope boundaries, what was actually done, who supplied
      what, quantities. Where the records genuinely don't answer, say so
      (known=false) rather than guessing.
    PROMPT
    content: [ { type: "text", text: "THE JOB'S ACTUAL COSTING LINES (section | work | quantity):\n#{items_text}\n\nQUESTIONS:\n#{q_text}" } ],
    schema: ANSWER_SCHEMA
  )["answers"]
end

results = []
JOBS.each do |job, id|
  while Estimate.uncached { Estimate.where(status: "processing").exists? }
    puts "waiting for in-flight run… (#{Time.current.strftime('%H:%M')})"
    sleep 120
    ActiveRecord::Base.connection_pool.release_connection
  end

  e = Estimate.find(id)
  questions = Array(e.open_questions).reject { |q| q["skipped"] }
  if questions.empty?
    puts "#{job}: no pending questions, skipping improve"
  else
    client = Ai::Client.new
    answers = oracle_answers(job, questions, client)
    by_id = answers.to_h { |a| [ a["id"], a ] }
    answered, skipped = questions.partition { |q| by_id[q["id"]]&.dig("known") }
    puts "#{job}: #{answered.size} answered from actuals, #{skipped.size} unanswerable"

    e.update!(
      clarifications: Array(e.clarifications) + answered.map { |q| q.slice("question").merge("answer" => by_id[q["id"]]["answer"]) },
      open_questions: skipped.map { |q| q.merge("skipped" => true) }
    )
    if answered.any?
      affected = e.sections.where(name: answered.flat_map { |q| Array(q["sections"]) }.uniq)
      puts "  re-costing #{affected.count} sections…"
      e.update!(costed_sections: e.costed_sections - affected.map(&:name))
      affected.destroy_all
      e.update!(status: "processing", error_message: nil, progress_note: "Improving with answers…")
      begin
        EstimateGenerator.new(e).call(resume: true)
        puts "  -> #{e.reload.status}, #{e.line_items.count} items"
      rescue StandardError => ex
        puts "  -> FAILED: #{ex.message.to_s.truncate(150)}"
        next
      end
    end
  end

  puts "#{job}: scoring…"
  gt = JSON.parse(File.read(Rails.root.join("eval/ground_truth/#{job}.json")))
  score = QuantityScorer.new(gt, e.reload).call
  bench_row = CSV.read(Rails.root.join("eval/baselines/#{job}.csv"), headers: true).find { |r| r["category"] == "__TOTAL__" }
  bench = (bench_row["actual_total"].presence || bench_row["human_estimate_total"]).to_f
  total_err = ((e.line_items.sum { |i| i.total.to_f } / FACTORS.fetch(job) - bench) / bench * 100).round(1)
  File.write(Rails.root.join("eval/results/quantity/#{job}_answered.json"), JSON.pretty_generate(score.merge(total_err: total_err)))
  results << { job: job, within20: score[:qty_within_20_pct], medape: score[:qty_median_ape_pct], total: total_err }
  puts "  #{job}: within20 #{score[:qty_within_20_pct]}%, medAPE #{score[:qty_median_ape_pct]}%, total #{total_err}%"
end

puts
results.each { |r| puts format("%-14s within20 %6s  medAPE %6s  total %6s%%", r[:job], r[:within20], r[:medape], r[:total]) }
puts "oracle chain done"
