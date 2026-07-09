# Forms a calibration pair from a training upload (the builder's own
# estimate, with per-category totals extracted at ingest) and this system's
# estimate of the same plans, then re-derives the builder's profile from all
# accumulated pairs. Derivation carries its own do-no-harm gates: aligned
# builders get a recorded no-op, never an adjustment.
class CalibrationPairer
  EXCLUDE = /variation|margin|contingency|\bgst\b|labour hours/i

  def initialize(training_document, estimate)
    @doc = training_document
    @estimate = estimate
  end

  def call
    theirs = Hash.new(0.0)
    Array(@doc.extraction["category_totals"]).each do |row|
      next if row["category"].to_s =~ EXCLUDE
      value = row["actual_total"].to_f.positive? ? row["actual_total"].to_f : row["quoted_total"].to_f
      theirs[TradeBucket.for(row["category"])] += value
    end
    return nil if theirs.values.sum < 10_000

    ours = Hash.new(0.0)
    @estimate.sections.includes(:line_items).each do |s|
      base = s.line_items.reject { |i| i.description.to_s.start_with?(CalibrationProfile::ADJUSTMENT_PREFIX) }
                         .sum { |i| i.total.to_f }
      ours[TradeBucket.for(s.name)] += base
    end
    # escalate their historical dollars to today before comparing
    factor = PriceEscalation.factor(@doc.priced_on)
    theirs.transform_values! { |v| v * factor }

    pair = { "job" => @doc.name, "doc_id" => @doc.id,
             "buckets" => theirs.keys.index_with { |b| { "ours" => ours[b].round, "theirs" => theirs[b].round } } }

    profile = CalibrationProfile.find_or_initialize_by(user: @doc.user)
    pairs = Array(profile.pairs).reject { |p| p["doc_id"] == @doc.id } + [ pair ]
    profile.update!(pairs: pairs) if profile.persisted?
    result = CalibrationProfile.derive!(@doc.user, pairs, notes: "auto-derived from #{pairs.size} uploaded job(s)")
    result.update!(pairs: pairs)
    result
  end
end
