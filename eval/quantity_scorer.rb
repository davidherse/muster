# Scores a generated estimate against a job's ground-truth takeoff
# (eval/ground_truth/<job>.json): structure coverage and quantity accuracy.
# Prices are ignored entirely.
#
# Usage (from a runner script):
#   scorer = QuantityScorer.new(ground_truth, estimate)
#   result = scorer.call   # metrics hash; result[:alignment] carries detail
class QuantityScorer
  ALIGN_SCHEMA = {
    type: "object",
    additionalProperties: false,
    required: %w[matches],
    properties: {
      matches: {
        type: "array",
        description: "One entry per ground-truth item that the generated estimate covers (fully or partly). Omit ground-truth items nothing covers.",
        items: {
          type: "object",
          additionalProperties: false,
          required: %w[gt est qty_comparable],
          properties: {
            gt: { type: "integer", description: "Ground-truth item index" },
            est: {
              type: "array", items: { type: "integer" },
              description: "Generated item index(es) that cover this scope. A generated item may cover several ground-truth lines and vice versa."
            },
            qty_comparable: {
              type: "boolean",
              description: "true ONLY when the ground-truth quantity and the matched generated quantity(ies) measure the same physical thing in the same unit (m2 vs m2, ea vs ea, lm vs lm, hours vs hours) so they can be numerically compared. false for lump-vs-anything, unit mismatches, or partial-scope matches."
            }
          }
        }
      }
    }
  }.freeze

  BATCH = 80

  def initialize(ground_truth, estimate, client: Ai::Client.new)
    @gt = ground_truth
    @estimate = estimate
    @client = client
  end

  def call
    gt_items = @gt["items"]
    est_items = flat_estimate_items
    matches = []
    gt_items.each_slice(BATCH).with_index do |slice, batch_i|
      offset = batch_i * BATCH
      result = @client.complete_json(
        system: [ { type: "text", text: instructions } ],
        content: [ { type: "text", text: alignment_text(slice, offset, est_items) } ],
        schema: ALIGN_SCHEMA
      )
      matches.concat(Array(result["matches"]))
    end
    metrics(gt_items, est_items, matches)
  end

  private

  def instructions
    <<~PROMPT
      You are aligning an AI-generated construction estimate against the human
      estimator's ground-truth takeoff for the SAME job. For each ground-truth
      line, find the generated line(s) covering the same physical scope —
      match on the work itself, not on wording or section names (different
      estimates structure sections differently; demolition of a wall may sit
      under 'Demolition' in one and 'Carpentry' in the other).

      - Only report a match when the generated item genuinely covers the
        ground-truth scope (fully, or as the clear counterpart at a coarser/
        finer breakdown). Do not force matches.
      - qty_comparable: true only for same-unit physical measures of the same
        scope boundary. When one side is a lump/allowance, or units differ,
        or the generated item bundles more scope than the ground-truth line,
        it is false.
    PROMPT
  end

  def alignment_text(gt_slice, offset, est_items)
    gt_lines = gt_slice.each_with_index.map do |it, i|
      "#{offset + i} | #{it['section']} | #{it['description']} | #{it['quantity']} #{it['uom']} (#{it['quantity_kind']})"
    end
    est_lines = est_items.each_with_index.map do |it, i|
      "#{i} | #{it[:section]} | #{it[:description]} | #{it[:quantity]} #{it[:uom]}"
    end
    <<~TEXT
      GROUND-TRUTH TAKEOFF ITEMS (index | section | description | qty uom (kind)):
      #{gt_lines.join("\n")}

      GENERATED ESTIMATE ITEMS (index | section | description | qty uom):
      #{est_lines.join("\n")}

      Report matches for the ground-truth items listed above.
    TEXT
  end

  def flat_estimate_items
    @estimate.sections.order(:position).flat_map do |section|
      section.line_items.order(:position).map do |item|
        { section: section.name, description: item.description,
          quantity: item.quantity.to_f, uom: item.uom }
      end
    end
  end

  def metrics(gt_items, est_items, matches)
    matched_gt = matches.map { |m| m["gt"] }.uniq.select { |i| i < gt_items.size }
    matched_est = matches.flat_map { |m| Array(m["est"]) }.uniq.select { |i| i < est_items.size }

    # Section coverage: a ground-truth section counts as covered when at
    # least half its items are matched.
    section_cov = gt_items.each_with_index.group_by { |it, _| it["section"] }.map do |section, pairs|
      idxs = pairs.map(&:last)
      covered = idxs.count { |i| matched_gt.include?(i) }
      { section: section, items: idxs.size, covered: covered }
    end

    # Quantity accuracy over comparable matched pairs.
    qty_pairs = matches.filter_map do |m|
      next unless m["qty_comparable"]
      gt = gt_items[m["gt"]] or next
      next unless gt["quantity_kind"] == "measured" && gt["quantity"].to_f.positive?
      est_qty = Array(m["est"]).sum { |i| est_items[i]&.dig(:quantity).to_f }
      next unless est_qty.positive?
      { gt_index: m["gt"], description: gt["description"], uom: gt["uom"],
        gt_qty: gt["quantity"].to_f, est_qty: est_qty,
        ape: ((est_qty - gt["quantity"].to_f) / gt["quantity"].to_f * 100).round(1) }
    end
    apes = qty_pairs.map { |p| p[:ape].abs }.sort

    {
      job: @gt["job"],
      estimate_id: @estimate.id,
      gt_items: gt_items.size,
      est_items: est_items.size,
      item_recall_pct: pct(matched_gt.size, gt_items.size),
      item_precision_pct: pct(matched_est.size, est_items.size),
      section_coverage_pct: pct(section_cov.count { |s| s[:covered] * 2 >= s[:items] }, section_cov.size),
      qty_pairs: qty_pairs.size,
      qty_median_ape_pct: apes.any? ? apes[apes.size / 2] : nil,
      qty_within_20_pct: apes.any? ? pct(apes.count { |a| a <= 20 }, apes.size) : nil,
      sections: section_cov,
      quantity_detail: qty_pairs,
      unmatched_gt: (0...gt_items.size).reject { |i| matched_gt.include?(i) }
                      .map { |i| "#{gt_items[i]['section']}: #{gt_items[i]['description']}" },
      alignment: matches
    }
  end

  def pct(num, den)
    den.zero? ? nil : (100.0 * num / den).round(1)
  end
end
