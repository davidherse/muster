class CreateTrainingDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :training_documents do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name
      t.string :status, null: false, default: "pending"
      t.json :questionnaire, null: false, default: {}
      t.json :extraction, null: false, default: {}
      t.text :error_message

      t.timestamps
    end
  end
end
