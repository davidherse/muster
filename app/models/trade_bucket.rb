# Maps section/category names into canonical trade buckets, shared by the
# accuracy autopsy and the scoped rate retrieval in estimate generation.
module TradeBucket
  BUCKETS = {
    "preliminaries" => /prelim|insurance|health|safety|temporary|hire|scaffold/,
    "demo/site/earthworks" => /demoli|site prep|earthwork|excavat|asbestos|termite/,
    "raise/structure" => /rais|restump|steel|concrete|blockwork|masonry|footing|fram|floor system|truss|bracing|pier/,
    "wet areas" => /waterproof|tiling|tile/,
    "envelope" => /roof|cladding|window|door|glaz|external stair|balustrade|batten|soffit|lockup/,
    "services" => /electric|plumb|solar|air.?con|mechanical|skylight|gas|hot water/,
    "linings/insulation" => /lining|plaster|insulat|villaboard/,
    "fitout" => /joinery|cabinet|fixing|fixture|fitting|stair|shower screen|mirror|appliance|pc item/,
    "painting" => /paint|silicone|caulk/,
    "floors" => /floor covering|carpet|timber floor|sanding|coverings/,
    "external works" => /fenc|retain|landscap|driveway|pool|pergola|carport|external work/,
    "cleaning/other" => /clean|variat|restoration|rectification|order|note/
  }.freeze

  def self.for(name)
    n = name.to_s.downcase
    BUCKETS.each { |bucket, pattern| return bucket if n.match?(pattern) }
    "cleaning/other"
  end
end
