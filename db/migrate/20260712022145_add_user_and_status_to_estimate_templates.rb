class AddUserAndStatusToEstimateTemplates < ActiveRecord::Migration[8.1]
  def change
    add_reference :estimate_templates, :user, null: true, foreign_key: true
    add_column :estimate_templates, :status, :string, null: false, default: "active"
  end
end
