namespace :estimator do
  desc "Escalate base price book rates by a percentage (quarterly ABS PPI update)"
  task :escalate_prices, [ :percent ] => :environment do |_t, args|
    pct = Float(args[:percent] || abort("usage: estimator:escalate_prices[2.5]"))
    factor = 1 + (pct / 100.0)
    stamp = Time.current.strftime("%Y-%m")
    count = 0
    PriceBookItem.base.find_each do |item|
      item.update_columns(
        unit_cost: (item.unit_cost * factor).round(2),
        source: "#{item.source} | escalated +#{pct}% #{stamp}"
      )
      count += 1
    end
    puts "Escalated #{count} base price book items by +#{pct}% (#{stamp})."
    puts "Source: ABS Producer Price Indexes (inputs to house construction) — see docs/PRICING_SOURCES.md"
  end
end
