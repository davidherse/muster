class CreatePriceBookItems < ActiveRecord::Migration[8.1]
  def change
    create_table :price_book_items do |t|
      t.string :category, null: false
      t.text :description, null: false
      t.string :item_type
      t.string :uom
      t.decimal :unit_cost, precision: 12, scale: 2, null: false
      t.integer :sample_count, default: 1
      t.string :source

      t.timestamps
    end
  end
end
