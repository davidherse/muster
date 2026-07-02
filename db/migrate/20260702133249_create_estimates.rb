class CreateEstimates < ActiveRecord::Migration[8.1]
  def change
    create_table :estimates do |t|
      t.references :user, null: false, foreign_key: true
      t.references :estimate_template, null: true, foreign_key: true
      t.string :name, null: false
      t.string :status, null: false, default: "draft"
      t.text :prompt
      t.string :building_type
      t.string :floor_area
      t.text :error_message
      t.json :plan_summary
      t.decimal :total_low, precision: 14, scale: 2
      t.decimal :total, precision: 14, scale: 2
      t.decimal :total_high, precision: 14, scale: 2
      t.integer :progress, default: 0
      t.string :progress_note

      t.timestamps
    end
  end
end
