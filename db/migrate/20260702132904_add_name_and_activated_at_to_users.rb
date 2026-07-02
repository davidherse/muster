class AddNameAndActivatedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :name, :string
    add_column :users, :activated_at, :datetime
  end
end
