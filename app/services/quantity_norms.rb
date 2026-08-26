# Derives a builder's QUANTITY norms from their training uploads: how many
# labour hours and measured units they actually carry per m² of works area,
# and supervision hours per week. Deterministic — no AI. Norms are how the
# builder's past takeoffs teach future quantities; prices are not involved.
#
# Stored on accounts.quantity_norms:
#   {
#     "groups" => {
#       "whole" => {                     # or "small" (partial/small_works docs)
#         "buckets" => { "<trade bucket>" => { "<uom>" => { "per_m2" =>, "n" =>, "min" =>, "max" => } } },
#         "supervision_hours_per_week" => { "value" =>, "n" =>, "min" =>, "max" => },
#         "docs" => n
#       }
#     },
#     "derived_at" => iso8601
#   }
class QuantityNorms
  SMALL_CLASSES = %w[partial_interior_renovation small_works].freeze
  SUPERVISION = /supervis|project manage|coordinat/i
  # Units worth learning as per-m² intensities.
  NORM_UOMS = { /\Ahours?\z|\Ahr\z/i => "hour", /\Am2\z|\Asqm\z/i => "m2", /\Alm\z|\Am\z/i => "lm" }.freeze

  def self.derive!(account)
    new(account).derive!
  end

  def initialize(account)
    @account = account
  end

  def derive!
    docs = @account.training_documents.where(status: "completed")
    per_doc = docs.filter_map { |doc| doc_intensities(doc) }
    return @account.update!(quantity_norms: nil) if per_doc.empty?

    groups = per_doc.group_by { |d| d[:group] }.transform_values { |ds| aggregate(ds) }
    @account.update!(quantity_norms: { "groups" => groups, "derived_at" => Time.current.iso8601 })
    @account.quantity_norms
  end

  # The norms group matching a project class, falling back to the other group.
  def self.for_class(account, project_class)
    groups = account&.quantity_norms&.dig("groups") or return nil
    key = SMALL_CLASSES.include?(project_class.to_s) ? "small" : "whole"
    groups[key] || groups.values.first
  end

  private

  # One doc's takeoff intensities: measured quantities per trade bucket per
  # m² of works area, plus supervision hours/week.
  def doc_intensities(doc)
    q = doc.questionnaire.to_h
    area = q["works_floor_area_m2"].to_f
    return nil unless area.positive?

    items = PriceBookItem.from_training_doc(@account, doc.id)
                         .select { |i| i.context.to_h["qty_kind"] == "measured" && i.context.to_h["qty"].to_f.positive? }
    return nil if items.empty?

    buckets = Hash.new { |h, k| h[k] = Hash.new(0.0) }
    supervision_hours = 0.0
    items.each do |item|
      uom = canonical_uom(item.uom) or next
      qty = item.context.to_h["qty"].to_f
      if uom == "hour" && item.description.to_s.match?(SUPERVISION)
        supervision_hours += qty
        next
      end
      buckets[TradeBucket.for(item.category)][uom] += qty
    end

    months = q["duration_months"].to_f
    {
      group: SMALL_CLASSES.include?(EstimateQuestionnaire::PROJECT_TYPES[q["project_type"]].to_s) ? "small" : "whole",
      per_m2: buckets.transform_values { |uoms| uoms.transform_values { |total| (total / area).round(4) } },
      supervision_hours_per_week: months.positive? && supervision_hours.positive? ? (supervision_hours / (months * 4.33)).round(2) : nil
    }
  end

  def aggregate(docs)
    bucket_keys = docs.flat_map { |d| d[:per_m2].keys }.uniq
    buckets = bucket_keys.to_h do |bucket|
      uoms = docs.flat_map { |d| d[:per_m2][bucket]&.keys || [] }.uniq
      [ bucket, uoms.to_h do |uom|
        values = docs.filter_map { |d| d[:per_m2].dig(bucket, uom) }
        [ uom, stat(values) ]
      end ]
    end
    sup = docs.filter_map { |d| d[:supervision_hours_per_week] }
    {
      "buckets" => buckets,
      "supervision_hours_per_week" => supervision_norm(sup),
      "docs" => docs.size
    }.compact
  end

  # Do-no-harm gate: a supervision norm only acts when the builder's jobs
  # agree with each other. Wildly inconsistent readings (usually one
  # mis-extracted line) must do nothing rather than swing estimates.
  def supervision_norm(values)
    return nil if values.empty?
    return nil if values.size > 1 && values.max > values.min * 3
    { "value" => median(values), "n" => values.size, "min" => values.min, "max" => values.max }
  end

  def stat(values)
    { "per_m2" => median(values), "n" => values.size, "min" => values.min, "max" => values.max }
  end

  def median(values)
    sorted = values.sort
    mid = sorted.size / 2
    (sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0).round(4)
  end

  def canonical_uom(uom)
    NORM_UOMS.each { |pattern, canon| return canon if uom.to_s.strip.match?(pattern) }
    nil
  end
end
