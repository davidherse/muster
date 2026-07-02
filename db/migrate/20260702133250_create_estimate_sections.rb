class CreateEstimateSections < ActiveRecord::Migration[8.1]
  def change
    create_table :estimate_sections do |t|
      t.references :estimate, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :name, null: false

      t.timestamps
    end
  end
end
