class CreateEstimateTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :estimate_templates do |t|
      t.string :name, null: false
      t.text :description
      t.json :sections, null: false, default: []

      t.timestamps
    end
  end
end
