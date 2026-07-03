class AddTieringToPriceBookItems < ActiveRecord::Migration[8.1]
  def change
    add_column :price_book_items, :source_kind, :string, null: false, default: "base"
    add_reference :price_book_items, :user, null: true, foreign_key: true
    add_column :price_book_items, :context, :json, null: false, default: {}
  end
end
