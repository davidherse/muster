class AddAssessmentToEstimates < ActiveRecord::Migration[8.1]
  def change
    add_column :estimates, :assessment, :json, null: false, default: {}
  end
end
