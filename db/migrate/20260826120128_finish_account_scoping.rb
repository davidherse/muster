class FinishAccountScoping < ActiveRecord::Migration[8.1]
  def change
    change_column_null :users, :account_id, false
    change_column_null :estimates, :account_id, false
    change_column_null :training_documents, :account_id, false
    change_column_null :estimates, :user_id, true
    change_column_null :training_documents, :user_id, true
    remove_column :users, :quantity_norms, :json
    remove_column :users, :onboarded_at, :datetime
    remove_reference :estimate_templates, :user, index: true
    remove_reference :price_book_items, :user, index: true
  end
end
