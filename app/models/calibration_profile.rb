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
  # bias_pct is how far THEIR quoting runs relative to OURS: positive means
  # they carry more in that bucket than we produce.
  def self.derive!(user, pairs, notes: nil)
    by_bucket = Hash.new { |h, k| h[k] = [] }
    pairs.each do |pair|
      pair["buckets"].each do |bucket, v|
        ours = v["ours"].to_f
        theirs = v["theirs"].to_f
        next unless ours.positive? && theirs > 5_000
        by_bucket[bucket] << ((theirs - ours) / ours * 100)
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
    profile.update!(buckets: buckets, derived_from: pairs.map { |p| p["job"] }, notes: notes)
    profile
  end

  def bias_for(bucket)
    buckets.dig(bucket, "bias_pct")
  end

  def reference_text
    return nil if buckets.blank?
    lines = buckets.map do |bucket, v|
      dir = v["bias_pct"].positive? ? "ABOVE" : "BELOW"
      "  - #{bucket}: this builder's own estimates run ~#{v['bias_pct'].abs}% #{dir} the book-grounded level (#{v['n']} graded jobs)"
    end
    "BUILDER CALIBRATION (learned from this builder's graded estimates — align section pricing and classification toward their style; this reflects how they value and carry work, including regional pricing):\n#{lines.join("\n")}"
  end
end
