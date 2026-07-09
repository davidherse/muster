class AddDescriptionToTrainingDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :training_documents, :description, :text
  end
end
