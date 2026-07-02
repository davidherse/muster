class AddCostedSectionsToEstimates < ActiveRecord::Migration[8.1]
  def change
    add_column :estimates, :costed_sections, :json, null: false, default: []
  end
end
