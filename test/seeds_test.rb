require "test_helper"
require "csv"

# The base price book ships as a CSV loaded by db/seeds.rb. Deploys run
# `rails db:seed` against a database that already carries the book, so rows
# added to the CSV must arrive without duplicating the ones already there.
class SeedsTest < ActiveSupport::TestCase
  PREMIUM_COMPOSITE = "Whole-house repaint composite - full repaint, premium finish (high-end / luxury spec) - per m² floor".freeze

  test "the base price book CSV carries the premium repaint composite" do
    rows = CSV.read(Rails.root.join("db/seed_data/price_book.csv"), headers: true)
    premium = rows.find { |r| r["description"].to_s.include?("premium finish") }

    assert premium, "expected a premium-finish whole-house repaint composite in the CSV"
    assert_equal PREMIUM_COMPOSITE, premium["description"]
    assert_equal "Painting", premium["category"]
    assert_equal "m2 floor", premium["uom"]
    assert_equal 300.0, premium["unit_cost"].to_f
  end

  test "seeding an already-seeded book adds only the rows it is missing" do
    capture_io { Rails.application.load_seed }
    seeded = PriceBookItem.base.count
    assert seeded.positive?, "expected the seed to load the base price book"
    assert PriceBookItem.base.exists?(description: PREMIUM_COMPOSITE)

    PriceBookItem.base.where(description: PREMIUM_COMPOSITE).delete_all
    capture_io { Rails.application.load_seed }

    assert_equal seeded, PriceBookItem.base.count
    assert PriceBookItem.base.exists?(description: PREMIUM_COMPOSITE)
  end
end
