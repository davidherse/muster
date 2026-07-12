# Extracts line-item ground truth (structure + quantities, no prices) from a
# job's human costing spreadsheet, for the quantity/structure eval.
#
#   JOB=carson bin/rails runner eval/extract_ground_truth.rb
#   JOB=all    bin/rails runner eval/extract_ground_truth.rb
#
# Writes eval/ground_truth/<job>.json. Idempotent: skips jobs whose file
# already exists unless FORCE=1.
require "roo"

$stdout.sync = true

DOCS = {
  "hilda" => "Hilda - J1068-JobCostingsActual-20260609051503.xlsx",
  "constitution" => "Constitution - J1135-JobCostingsActual-20260609050935.xlsx",
  "benecia" => "BENECIA RENOVATION.xlsx",
  "carberry" => "Carberry - 1522 - Built_Excel Workbook.xlsx",
  "carson" => "6 Carson - J1211-JobCostingsActual-20260703051052.xlsx",
  "huxham" => "17 Huxham - J1187-JobCostingsActual-20260703050859.xlsx",
  "rosalie" => "77 Rosalie - J1162-JobCostingsActual-20260703050947.xlsx"
}.freeze
DIR = "/Users/davidherse/Dropbox/Built Homes/esitmates".freeze
OUT_DIR = Rails.root.join("eval/ground_truth")
CHUNK_LINES = 220

SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: %w[sections items],
  properties: {
    sections: {
      type: "array", items: { type: "string" },
      description: "Section/work-group names in document order"
    },
    items: {
      type: "array",
      description: "Every real work line item (skip notes, blanks, $0 placeholder rows, headers, subtotals).",
      items: {
        type: "object",
        additionalProperties: false,
        required: %w[section description uom quantity quantity_kind],
        properties: {
          section: { type: "string" },
          description: { type: "string" },
          uom: { type: "string", description: "Unit as documented (m2, lm, ea, Hour, Week, Allowance...)" },
          quantity: { type: "number", description: "The ESTIMATED/quoted quantity — the human's takeoff. 1 for lump/allowance lines." },
          quantity_kind: {
            type: "string", enum: %w[measured lump],
            description: "'measured' only when the quantity counts real physical units the estimator took off (m2, lm, openings, hours). 'lump' for allowances, packages, and $-only lines. Progress-claim style quantities (fractional counts against package descriptions) are 'lump'."
          }
        }
      }
    }
  }
}.freeze

INSTRUCTIONS = <<~PROMPT
  You are digitising the STRUCTURE and QUANTITIES of a residential builder's
  own job costing/estimate spreadsheet — a ground-truth takeoff for evaluating
  AI estimates. Prices are irrelevant here; do not extract any dollar figures.

  - Record every real work line item under its section, in order.
  - quantity is the ESTIMATED (quoted) quantity — the human's original
    takeoff. Ignore actual/claimed quantity columns entirely: fractional
    counts (9.25) or counts against whole-package descriptions are progress
    claims, not takeoffs.
  - quantity_kind 'measured' only when the quantity counts physical units
    (m2, lm, each-openings, hours, weeks). Allowances, PC/PS sums, packages,
    and lines whose quantity is just 1-with-a-total are 'lump' with quantity 1.
  - Keep the builder's own section names and item wording verbatim.
PROMPT

def csv_lines(path)
  sheet = Roo::Spreadsheet.open(path, extension: File.extname(path).delete("."))
  csv = +""
  sheet.sheets.each do |name|
    sheet.default_sheet = name
    next if sheet.last_row.to_i.zero?
    csv << "### SHEET: #{name}\n" << sheet.to_csv
  rescue StandardError
    next
  end
  csv.lines
end

def extract(job, filename)
  path = File.join(DIR, filename)
  abort("missing: #{path}") unless File.exist?(path)
  client = Ai::Client.new
  lines = csv_lines(path)
  header = lines.first.to_s
  chunks = lines.drop(1).each_slice(CHUNK_LINES).to_a
  merged = { "sections" => [], "items" => [] }
  chunks.each_with_index do |chunk, i|
    puts "  #{job}: chunk #{i + 1}/#{chunks.size}"
    result = client.complete_json(
      system: [ { type: "text", text: INSTRUCTIONS } ],
      content: [ { type: "text", text: "COSTING SPREADSHEET (#{filename}) AS CSV — part #{i + 1} of #{chunks.size}. Section names may continue from a previous part.\n#{header}#{chunk.join}" },
                 { type: "text", text: "Extract the sections and work line items with their estimated quantities." } ],
      schema: SCHEMA
    )
    merged["sections"] |= Array(result["sections"])
    merged["items"].concat(Array(result["items"]))
  end
  merged["job"] = job
  merged["source"] = filename
  FileUtils.mkdir_p(OUT_DIR)
  File.write(OUT_DIR.join("#{job}.json"), JSON.pretty_generate(merged))
  puts "  #{job}: #{merged['sections'].size} sections, #{merged['items'].size} items -> eval/ground_truth/#{job}.json (#{client.usage_totals&.dig(:est_cost_usd) || '?'} USD)"
end

jobs = ENV["JOB"] == "all" ? DOCS.keys : [ ENV.fetch("JOB") ]
jobs.each do |job|
  out = OUT_DIR.join("#{job}.json")
  if File.exist?(out) && ENV["FORCE"].blank?
    puts "  #{job}: exists, skipping (FORCE=1 to redo)"
    next
  end
  extract(job, DOCS.fetch(job))
end
puts "done"
