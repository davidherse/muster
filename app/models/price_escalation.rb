# Escalates historical rates to current dollars using Brisbane residential
# construction cost movement (ABS producer price indexes + industry indices —
# see docs/PRICING_SOURCES.md). Anchor points are consistent with the factors
# applied to the seeded base price book; linear interpolation between them.
#
# Update CURRENT_ANCHOR (and append an anchor) when running quarterly
# escalations so training uploads keep landing in today's dollars.
module PriceEscalation
  # [fractional year, multiply-to-reach-mid-2026]
  ANCHORS = [
    [ 2021.5, 1.29 ],
    [ 2023.0, 1.17 ],
    [ 2024.75, 1.10 ],
    [ 2025.75, 1.04 ],
    [ 2026.5, 1.00 ]
  ].freeze

  def self.factor(date)
    return 1.0 if date.blank?
    y = date.year + (date.month - 0.5) / 12.0
    return ANCHORS.first[1] if y <= ANCHORS.first[0]
    return ANCHORS.last[1] if y >= ANCHORS.last[0]

    ANCHORS.each_cons(2) do |(y1, f1), (y2, f2)|
      next unless y.between?(y1, y2)
      return (f1 + (f2 - f1) * (y - y1) / (y2 - y1)).round(4)
    end
    1.0
  end
end
