# A builder's quoting fingerprint, learned from graded pairs: for each trade
# bucket, how their own estimates run relative to this system's book-grounded
# output. Derived from uploaded (their estimate, our estimate of the same
# plans) pairs; captures valuation posture (lean/premium), classification
# style (where they carry supervision/site costs), and regional pricing in
# one mechanism. Applied as generation nudges plus computed review bands —
# never as silent post-hoc scaling.
class CalibrationProfile < ApplicationRecord
  belongs_to :user

  # Learn only what is consistent: a bucket calibrates when at least
  # MIN_PAIRS pairs agree in direction and the median move is material.
  MIN_PAIRS = 2
  MIN_BIAS_PCT = 10
  MAX_BIAS_PCT = 50

  # pairs: [ { "job" =>, "buckets" => { bucket => { "ours" =>, "theirs" => } } } ]
  # Two-component fingerprint: a GLOBAL bias (median of per-job total deltas —
  # region and overall posture, robust from few jobs) plus per-bucket
  # RESIDUALS relative to it (classification/valuation style). Positive means
  # they carry more than we produce.
  def self.derive!(user, pairs, notes: nil)
    total_deltas = pairs.filter_map do |pair|
      ours = pair["buckets"].values.sum { |v| v["ours"].to_f }
      theirs = pair["buckets"].values.sum { |v| v["theirs"].to_f }
      (theirs - ours) / ours * 100 if ours.positive?
    end
    global = total_deltas.empty? ? 0 : total_deltas.sort[total_deltas.size / 2].clamp(-MAX_BIAS_PCT, MAX_BIAS_PCT).round

    by_bucket = Hash.new { |h, k| h[k] = [] }
    pairs.each do |pair|
      pair["buckets"].each do |bucket, v|
        ours = v["ours"].to_f
        theirs = v["theirs"].to_f
        next unless ours > 5_000 && theirs > 5_000
        by_bucket[bucket] << ((theirs - ours) / ours * 100 - global)
      end
    end

    buckets = {}
    by_bucket.each do |bucket, deltas|
      next if deltas.size < MIN_PAIRS
      same_sign = [ deltas.count(&:positive?), deltas.count(&:negative?) ].max
      next if same_sign < (deltas.size * 2.0 / 3).ceil
      median = deltas.sort[deltas.size / 2]
      next if median.abs < MIN_BIAS_PCT
      buckets[bucket] = { "bias_pct" => median.clamp(-MAX_BIAS_PCT, MAX_BIAS_PCT).round, "n" => deltas.size }
    end

    profile = find_or_initialize_by(user: user)
    profile.update!(global_bias_pct: global, buckets: buckets, derived_from: pairs.map { |p| p["job"] }, notes: notes)
    profile
  end

  # Effective bias = global posture/region + bucket residual.
  def bias_for(bucket)
    residual = buckets.dig(bucket, "bias_pct") || 0
    total = global_bias_pct.to_i + residual
    total.zero? ? nil : total
  end

  # Deterministic application: a visible, labelled adjustment line per
  # section whose bucket carries a calibrated bias — never silent scaling.
  # Returns total dollars adjusted.
  def apply!(estimate)
    adjusted = 0.0
    estimate.sections.includes(:line_items).each do |section|
      bias = bias_for(TradeBucket.for(section.name))
      next unless bias
      next unless bias.abs >= 5
      base = section.line_items.reject { |i| i.description.to_s.start_with?(ADJUSTMENT_PREFIX) }.sum { |i| i.total.to_f }
      next if base < 1_000
      delta = (base * bias / 100.0).round(2)
      existing = section.line_items.detect { |i| i.description.to_s.start_with?(ADJUSTMENT_PREFIX) }
      existing&.destroy
      section.line_items.create!(
        position: (section.line_items.maximum(:position) || 0) + 1,
        description: "#{ADJUSTMENT_PREFIX} (#{bias.positive? ? '+' : ''}#{bias}% — learned from your graded estimates)",
        item_type: nil, uom: "Allowance", quantity: 1, unit_cost: delta, total: delta,
        confidence: "medium",
        assumptions: "Deterministic calibration: global #{global_bias_pct.to_i}% posture/region #{buckets.key?(TradeBucket.for(section.name)) ? "+ #{buckets.dig(TradeBucket.for(section.name), 'bias_pct')}% bucket style" : ''} from #{derived_from.size} graded jobs. Remove by clearing your calibration profile."
      )
      adjusted += delta
    end
    adjusted.round
  end

  ADJUSTMENT_PREFIX = "Calibration adjustment".freeze

  def reference_text
    return nil if buckets.blank?
    lines = buckets.map do |bucket, v|
      dir = v["bias_pct"].positive? ? "ABOVE" : "BELOW"
      "  - #{bucket}: this builder's own estimates run ~#{v['bias_pct'].abs}% #{dir} the book-grounded level (#{v['n']} graded jobs)"
    end
    "BUILDER CALIBRATION (learned from this builder's graded estimates — align section pricing and classification toward their style; this reflects how they value and carry work, including regional pricing):\n#{lines.join("\n")}"
  end
end
