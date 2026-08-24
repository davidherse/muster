class AddQuantityNormsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :quantity_norms, :json
  end
end
