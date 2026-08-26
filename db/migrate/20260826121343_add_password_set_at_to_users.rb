class AddPasswordSetAtToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :password_set_at, :datetime
    execute "UPDATE users SET password_set_at = created_at"   # everyone so far chose their own
  end

  def down
    remove_column :users, :password_set_at
  end
end
