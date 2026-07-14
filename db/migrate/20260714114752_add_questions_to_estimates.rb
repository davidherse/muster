class AddQuestionsToEstimates < ActiveRecord::Migration[8.1]
  def change
    add_column :estimates, :open_questions, :json
    add_column :estimates, :clarifications, :json
  end
end
