require "csv"

# Builds the downloadable CSV for a completed estimate.
class EstimateCsv
  def initialize(estimate)
    @estimate = estimate
  end

  def generate
    CSV.generate do |csv|
      csv << [ "Estimate", @estimate.name ]
      csv << [ "Building Type", @estimate.building_type ]
      csv << [ "Floor Area (m2)", @estimate.floor_area ]
      csv << [ "Generated", @estimate.updated_at.strftime("%-d %b %Y") ]
      csv << [ "All amounts AUD ex. GST" ]
      csv << []
      csv << [ "Section", "Item", "Description", "Type", "UOM", "Qty", "Unit Cost",
               "Total", "Range Low", "Range High", "Confidence", "Assumptions" ]

      @estimate.sections.includes(:line_items).each_with_index do |section, s_idx|
        csv << [ "#{s_idx + 1}. #{section.name}", nil, nil, nil, nil, nil, nil,
                 money(section.subtotal), money(section.subtotal_low), money(section.subtotal_high) ]
        section.line_items.each_with_index do |item, i_idx|
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

  def money(value)
    value.nil? ? nil : format("%.2f", value)
  end
end
