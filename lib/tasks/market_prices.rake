# Market price tier: published, citable Australian cost references for job
# classes and trades the builder's own history doesn't cover. Consumer prices
# converted to ex-GST; they still include builder margin, so they are BOUNDS
# (context notes this), not builder-cost comparables.
#
#   bin/rails estimator:ingest_market
#
# Re-run on each new edition (Archicentre publishes annually); replaces all
# market entries. PriceEscalation keeps them current between editions.
namespace :estimator do
  desc "Ingest published market reference prices (Archicentre Australia Cost Guide)"
  task ingest_market: :environment do
    source = "Archicentre Australia Cost Guide 2026 | archicentreaustralia.com.au/resources/cost-guide | ex GST (published incl GST /1.1)"
    ctx = {
      "kind" => "published market reference",
      "note" => "consumer price incl builder margin, standard finishes — builder cost typically runs below; premium documented spec runs above"
    }

    rows = [
      [ "Wet Area Composites", "Bathroom/ensuite renovation — complete room, standard finishes (market band)", "room", 17_500, 35_000 ],
      [ "Wet Area Composites", "Kitchen renovation — complete room, standard finishes (market band)", "room", 23_000, 49_000 ],
      [ "Wet Area Composites", "Laundry renovation — complete room, standard finishes (market band)", "room", 10_000, 19_000 ],
      [ "Renovation Composites", "Internal renovation within existing building — standard finishes (market band)", "m2", 1_600, 3_900 ],
      [ "Renovation Composites", "New construction / extension shell (excl wet area fitout) (market band)", "m2", 2_700, 5_100 ],
      [ "Electrical", "Rewire whole house (market band)", "house", 9_500, 24_000 ],
      [ "Electrical", "New light point (excl fitting) (market band)", "ea", 125, 150 ],
      [ "Electrical", "Add power point (market band)", "ea", 125, 300 ],
      [ "Electrical", "Replace switchboard (market band)", "ea", 900, 3_000 ],
      [ "Plumbing", "Complete house re-plumbing, ~150m2 house (market band)", "house", 14_000, 24_000 ],
      [ "Plumbing", "Install toilet/basin/bath/shower (labour only, excl fitting supply) (market band)", "ea", 150, 555 ],
      [ "Plumbing", "Replace taps/shower rose/spouts (labour only) (market band)", "ea", 50, 250 ],
      [ "Plumbing", "Hot water service replacement (market band)", "ea", 1_400, 4_200 ],
      [ "Painting", "Interior painting — plaster/brick/timber, 1 undercoat 2 finish coats (market band)", "m2", 20, 40 ],
      [ "Painting", "Exterior timber painting — good condition (market band)", "m2", 25, 60 ],
      [ "Painting", "Exterior timber painting — poor condition (market band)", "m2", 45, 80 ],
      [ "Tiling", "Wall tiling laid, tiles to $30/m2 supply (market rate)", "m2", 135, 135 ],
      [ "Internal Linings", "Plasterboard incl furring channels (market band)", "m2", 81, 98 ],
      [ "Windows and Doors", "Awning/sliding window replacement incl hardware and finish (market band)", "m2", 460, 1_220 ],
      [ "Windows and Doors", "Double hung window replacement incl hardware and finish (market band)", "m2", 925, 1_625 ],
      [ "Windows and Doors", "Skylight supply and install (market band)", "ea", 720, 2_700 ],
      [ "Floor Coverings", "Carpet supply and lay excl underlay (market band)", "m2", 45, 165 ],
      [ "Floor Coverings", "Timber floor sanding and polishing (market band)", "m2", 75, 120 ],
      [ "Floor Coverings", "Tongue and groove flooring replacement (market band)", "m2", 180, 250 ],
      [ "Restumping", "Restump house, concrete stumps to 1.0m (market band)", "house", 14_000, 19_000 ],
      [ "Fencing and Retaining Walls", "Timber paling fence 1600-1800mm (market band)", "lm", 120, 170 ],
      [ "Concrete Works", "100mm reinforced concrete driveway (market band)", "m2", 105, 125 ],
      [ "Insulation", "Glasswool batts R1.5-R6.0 (market band)", "m2", 14, 27 ]
    ]

    PriceBookItem.market.delete_all
    rows.each do |category, description, uom, low, high|
      low_ex = (low / 1.1).round
      high_ex = (high / 1.1).round
      PriceBookItem.create!(
        category: category,
        description: description,
        item_type: "MatLab",
        uom: uom,
        unit_cost: ((low_ex + high_ex) / 2.0).round,
        sample_count: 1,
        source: source,
        source_kind: "market",
        context: ctx.merge("band_low" => low_ex, "band_high" => high_ex, "priced_on" => "2026-01-01")
      )
    end
    puts "Ingested #{PriceBookItem.market.count} market reference entries"
  end
end
