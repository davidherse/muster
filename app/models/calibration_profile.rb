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

    # A global bias exists only when the builder's totals sit CONSISTENTLY to
    # one side of ours (at most one job may disagree) and materially so —
    # deltas that straddle zero mean they already align with the book, and
    # the correct calibration is none. Then a leave-one-out check must show
    # the bias actually improves alignment on unseen jobs; otherwise zero.
    global = 0
    if total_deltas.size >= MIN_PAIRS
      one_sided = [ total_deltas.count(&:positive?), total_deltas.count(&:negative?) ].max >= total_deltas.size - (total_deltas.size >= 4 ? 1 : 0)
      median = total_deltas.sort[total_deltas.size / 2]
      if one_sided && median.abs >= 8 && loo_improves?(total_deltas)
        global = median.clamp(-MAX_BIAS_PCT, MAX_BIAS_PCT).round
      end
    end

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
    status = global.zero? ? "aligned with book pricing — no adjustment applied" : nil
    profile.update!(global_bias_pct: global, buckets: buckets,
                    derived_from: pairs.map { |p| p["job"] },
                    notes: [ notes, status ].compact.join(" | "))
    profile
  end

  # Leave-one-out: would applying the bias derived from the other jobs have
  # improved alignment on the held-out job? Calibration must earn its keep.
  def self.loo_improves?(total_deltas)
    return false if total_deltas.size < 3
    improvements = total_deltas.each_index.map do |i|
      rest = total_deltas.each_with_index.reject { |_, j| j == i }.map(&:first)
      bias = rest.sort[rest.size / 2]
      held = total_deltas[i]
      # post-calibration error on the held-out job vs its raw error
      post = ((1 + held / 100.0) / (1 + bias / 100.0) - 1) * 100
      held.abs - post.abs
    end
    improvements.sum.positive?
  end

  # Price adjustment uses the GLOBAL bias only. Bucket residuals encode
  # classification/presentation style (where this builder files money), and
  # applying them as price multipliers moves real dollars the wrong way —
  # they feed the template/presentation layer instead.
  def bias_for(bucket)
    g = global_bias_pct.to_i
    g.zero? ? nil : g
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
