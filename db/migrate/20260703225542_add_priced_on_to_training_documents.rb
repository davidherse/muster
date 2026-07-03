class AddPricedOnToTrainingDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :training_documents, :priced_on, :date
  end
end
