require "csv"

# --- Default estimate template -------------------------------------------
# Section layout mirrors Built Homes' historical job costing reports.
DEFAULT_SECTIONS = [
  { "name" => "Preliminaries", "hint" => "Insurance (QBCC HOW, public liability), QLeave, WHS, certification fees, engineering fees, surveys, project management" },
  { "name" => "Hire Items and Scaffolding", "hint" => "Temp fencing, scaffolding, trestles/planks, propping, misc hire equipment" },
  { "name" => "Temporary Services", "hint" => "Site toilet hire and servicing, temp power" },
  { "name" => "Site Preparation and Demolition", "hint" => "Demolition, strip-out, waste from demolition, protection of retained finishes" },
  { "name" => "Asbestos Removal", "hint" => "Testing, licensed removal and disposal (older homes)" },
  { "name" => "Termite Protection", "hint" => "Termite management system to slabs, penetrations and perimeter" },
  { "name" => "Earthworks", "hint" => "Cut/fill, excavation for footings, drilling piers, spoil removal" },
  { "name" => "Concrete Works", "hint" => "Footings, slabs, pump hire, reinforcement, formwork, x-ray of existing slabs" },
  { "name" => "Blockwork and Masonry", "hint" => "Block retaining walls, brickwork, core filling, lintels" },
  { "name" => "Structural Steel", "hint" => "Supply and install of beams, columns, connection plates" },
  { "name" => "Ground Floor Framing", "hint" => "Wall frames, floor framing to ground level" },
  { "name" => "Floor Systems, Deck and Posts", "hint" => "Bearers/joists, flooring sheets, decks, posts" },
  { "name" => "First Floor Framing", "hint" => "Upper level wall and floor framing" },
  { "name" => "Roof Framing", "hint" => "Trusses or stick roof framing, bracing, tie-downs" },
  { "name" => "Roofing", "hint" => "Roof sheeting/tiles, sarking, gutters, fascia, downpipes, flashings" },
  { "name" => "Windows and Doors", "hint" => "Window and external door supply and install per schedule" },
  { "name" => "Lockup Carpenter", "hint" => "Carpentry labour to lockup stage: external cladding, eaves, external doors" },
  { "name" => "Balustrades, Battens, Gates and External Stairs", "hint" => "External balustrade, fretwork, battening, gates, external stairs" },
  { "name" => "Electrical", "hint" => "Full electrical rough-in and fit-off, switchboard, power, lighting, data, smoke alarms" },
  { "name" => "Solar Power System", "hint" => "PV system supply and install if shown" },
  { "name" => "Plumbing and Drainage", "hint" => "Rough-in and fit-off, drainage, stormwater, fixtures connection, gas" },
  { "name" => "Mechanical Services / Air Conditioning", "hint" => "Ducted or split system air conditioning, ventilation" },
  { "name" => "Skylights", "hint" => "Skylights/roof windows supply and install" },
  { "name" => "Internal Stairs", "hint" => "Internal staircase supply and install, balustrade" },
  { "name" => "Insulation", "hint" => "Wall, ceiling and acoustic insulation" },
  { "name" => "Internal Linings", "hint" => "Plasterboard walls and ceilings, VJ linings, cornice" },
  { "name" => "Waterproofing", "hint" => "Wet area waterproofing to AS 3740, balconies" },
  { "name" => "Tiling", "hint" => "Wall and floor tiling, tile supply allowances, screeds" },
  { "name" => "Floor Coverings", "hint" => "Timber flooring, carpet, vinyl, floor sanding and polishing" },
  { "name" => "Fixing Carpentry", "hint" => "Internal doors, architraves, skirting, shelving, door furniture" },
  { "name" => "Joinery", "hint" => "Kitchen, vanities, wardrobes, laundry joinery, benchtops" },
  { "name" => "Rendering", "hint" => "Render to blockwork/brick, moulding details" },
  { "name" => "Glazing", "hint" => "Shower screens, mirrors, splashbacks, glass balustrade" },
  { "name" => "Fixtures and Fittings", "hint" => "Sanitaryware, tapware, appliances, door hardware allowances" },
  { "name" => "Painting", "hint" => "Internal and external painting, preparation" },
  { "name" => "Fencing and Retaining Walls", "hint" => "Boundary fencing, sleeper retaining walls" },
  { "name" => "Site Cleaning and Waste Removal", "hint" => "Skip bins, ongoing site cleaning, final builder's clean of site" },
  { "name" => "Internal Cleaning", "hint" => "Professional internal clean on completion" },
  { "name" => "Silicone and Caulking", "hint" => "Silicone and caulking on completion" },
  { "name" => "External Works and Landscaping", "hint" => "Driveways, paths, decks/pergolas, turf, landscaping if shown" }
].freeze

template = EstimateTemplate.find_or_initialize_by(name: "Built Homes Standard")
template.update!(
  description: "Standard residential build/renovation costing layout based on Built Homes' historical job costing reports. All amounts ex. GST.",
  sections: DEFAULT_SECTIONS
)
puts "Seeded template: #{template.name} (#{template.sections.size} sections)"

# --- Price book -----------------------------------------------------------
# Median unit rates extracted from historical job costings (actuals preferred
# over estimates), indexed to mid-2026 dollars using Brisbane residential
# construction cost escalation (ABS output prices): Hilda 2021-22 x1.29,
# Benecia 2022-23 x1.17, Constitution 2024-25 x1.10, Carberry 2025 x1.04.
# The source column records each item's provenance and applied factor.
csv_path = Rails.root.join("db/seed_data/price_book.csv")

# Context per source job so base rates read like user rates (what kind of
# job the rate came from). Derived from the source column's job name.
source_context = {
  /hilda/i => { "project_class" => "extension_and_renovation", "finish_level" => "High-end", "floor_area_m2" => 300, "note" => "double-storey rework in footprint" },
  /benecia/i => { "project_class" => "raise_and_build_under", "finish_level" => "High-end", "floor_area_m2" => 300, "note" => "raise + build-in-under with pool" },
  /constitution/i => { "project_class" => "extension_and_renovation", "finish_level" => "High-end", "floor_area_m2" => 400, "note" => "heavy-character reno, large glazing" },
  /carberry/i => { "project_class" => "extension_and_renovation", "finish_level" => "High-end", "floor_area_m2" => 330, "note" => "character weatherboard reno" }
}.freeze

# The job name in a row's source column ("Constitution", "Hilda") is what
# earns the row a context, and the context's project_class is what decides
# whether the rate binds on a given job — the generator prefers entries whose
# context matches this job's class and treats them as binding. A row whose
# source names no job falls through to the bare "composite/derived rate"
# note, carries no project_class, and so can never match: composite rows must
# name the job they came from.
context_for = lambda do |source|
  source_context.find { |pattern, _ctx| source.to_s.match?(pattern) }&.last || { "note" => "composite/derived rate" }
end

build_row = lambda do |row|
  {
    category: row["category"],
    description: row["description"],
    item_type: row["item_type"].presence,
    uom: row["uom"].presence,
    unit_cost: row["unit_cost"].to_d,
    sample_count: row["sample_count"].to_i,
    source: row["source"].presence || "historical",
    source_kind: "base",
    context: context_for.call(row["source"]).merge(
      row["uom"].to_s.match?(/allowance/i) ? { "scale" => "lump sum at source-job scope — derive a unit rate before reuse at different scope" } : {}
    ),
    created_at: Time.current,
    updated_at: Time.current
  }
end

# Seeding runs on every deploy, against a database that already carries the
# book: rows added to the CSV since the last release have to arrive without
# re-inserting the ones already there. Description is the identity — the CSV
# carries no ids. Fourteen descriptions appear twice (different source jobs);
# both copies land on first load, and a new row whose description matches an
# existing one is skipped rather than duplicated.
if csv_path.exist?
  csv_rows = CSV.read(csv_path, headers: true)
  if PriceBookItem.base.count.zero?
    PriceBookItem.insert_all(csv_rows.map { |row| build_row.call(row) })
    puts "Seeded base price book: #{PriceBookItem.base.count} items"
  else
    seeded = PriceBookItem.base.pluck(:description).to_set
    missing = csv_rows.reject { |row| seeded.include?(row["description"]) }
    if missing.any?
      PriceBookItem.insert_all(missing.map { |row| build_row.call(row) })
      puts "Added #{missing.size} new base price book items (#{PriceBookItem.base.count} total)"
    else
      puts "Base price book already seeded (#{PriceBookItem.base.count} items)"
    end
  end
end
