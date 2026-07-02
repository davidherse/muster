class AddQuestionnaireToEstimates < ActiveRecord::Migration[8.1]
  def change
    add_column :estimates, :questionnaire, :json, null: false, default: {}
  end
end
