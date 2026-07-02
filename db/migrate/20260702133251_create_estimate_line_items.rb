class CreateEstimateLineItems < ActiveRecord::Migration[8.1]
  def change
    create_table :estimate_line_items do |t|
      t.references :estimate_section, null: false, foreign_key: true
      t.integer :position, null: false
      t.text :description, null: false
      t.string :item_type
      t.string :uom
      t.decimal :quantity, precision: 12, scale: 3
      t.decimal :unit_cost, precision: 12, scale: 2
      t.decimal :total, precision: 14, scale: 2
      t.string :confidence
      t.text :assumptions

      t.timestamps
    end
  end
end
