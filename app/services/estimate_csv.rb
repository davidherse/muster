require "csv"

# Builds the downloadable CSV for a completed estimate. With a layout
# template (the builder's own section list, learned from their uploads),
# items render grouped and ordered the way THEIR estimates are laid out —
# sections map across by trade bucket.
class EstimateCsv
  def initialize(estimate, layout: nil)
    @estimate = estimate
    @layout = layout
  end

  def generate
    CSV.generate do |csv|
      csv << [ "Estimate", @estimate.name ]
      csv << [ "Building Type", @estimate.building_type ]
      csv << [ "Floor Area (m2)", @estimate.floor_area ]
      csv << [ "Generated", @estimate.updated_at.strftime("%-d %b %Y") ]
      csv << [ "Layout", @layout.name ] if @layout
      csv << [ "All amounts AUD ex. GST" ]
      csv << []
      csv << [ "Section", "Item", "Description", "Type", "UOM", "Qty", "Unit Cost",
               "Total", "Range Low", "Range High", "Confidence", "Assumptions" ]

      grouped_sections.each_with_index do |(name, items), s_idx|
        subtotal = items.sum { |i| i.total.to_f }
        low = items.sum(&:range_low)
        high = items.sum(&:range_high)
        csv << [ "#{s_idx + 1}. #{name}", nil, nil, nil, nil, nil, nil,
                 money(subtotal), money(low), money(high) ]
        items.each_with_index do |item, i_idx|
          csv << [ nil, "#{s_idx + 1}.#{i_idx + 1}", item.description, item.item_type, item.uom,
                   item.quantity&.to_f, money(item.unit_cost), money(item.total),
                   money(item.range_low), money(item.range_high), item.confidence, item.assumptions ]
        end
      end

      csv << []
      csv << [ "TOTAL (ex. GST)", nil, nil, nil, nil, nil, nil,
               money(@estimate.total), money(@estimate.total_low), money(@estimate.total_high) ]
    end
  end

  private

  # Without a layout: our sections as-is. With one: the builder's sections in
  # their documented order, our items assigned by trade bucket (first of
  # their sections sharing the bucket wins); unmatched work keeps its own
  # section name at the end rather than being forced somewhere wrong.
  def grouped_sections
    sections = @estimate.sections.includes(:line_items)
    return sections.map { |s| [ s.name, s.line_items.to_a ] } unless @layout

    theirs = @layout.sections.map { |s| s["name"] }
    bucket_owner = {}
    theirs.each { |name| bucket_owner[TradeBucket.for(name)] ||= name }

    grouped = Hash.new { |h, k| h[k] = [] }
    extras = []
    sections.each do |section|
      target = theirs.detect { |t| t.casecmp?(section.name) } || bucket_owner[TradeBucket.for(section.name)]
      if target
        grouped[target].concat(section.line_items.to_a)
      else
        extras << [ section.name, section.line_items.to_a ]
      end
    end
    theirs.filter_map { |name| [ name, grouped[name] ] if grouped[name].any? } + extras
  end

  def money(value)
    value.nil? ? nil : format("%.2f", value)
  end
end
