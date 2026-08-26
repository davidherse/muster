class CreateAccounts < ActiveRecord::Migration[8.1]
  # Plain table-backed classes so the migration doesn't depend on app models.
  class MigrationUser < ActiveRecord::Base; self.table_name = "users"; end
  class MigrationAccount < ActiveRecord::Base; self.table_name = "accounts"; end

  SCOPED_TABLES = %w[estimates training_documents estimate_templates price_book_items].freeze

  def up
    create_table :accounts do |t|
      t.string :name, null: false
      t.json :quantity_norms
      t.datetime :onboarded_at
      t.timestamps
    end
    add_reference :users, :account, index: true          # nullable until Task 3
    add_column :users, :role, :string, null: false, default: "member"
    SCOPED_TABLES.each { |table| add_reference table, :account, index: true }

    # One account per existing user, owned by that user, holding everything
    # they own today. Team members are folded in later by hand.
    MigrationUser.reset_column_information
    MigrationAccount.reset_column_information
    MigrationUser.find_each do |user|
      account = MigrationAccount.create!(
        name: user.name.presence || user.email_address,
        quantity_norms: user.quantity_norms,
        onboarded_at: user.onboarded_at
      )
      user.update_columns(account_id: account.id, role: "owner")
      SCOPED_TABLES.each do |table|
        execute "UPDATE #{table} SET account_id = #{account.id} WHERE user_id = #{user.id}"
      end
    end
  end

  def down
    SCOPED_TABLES.each { |table| remove_reference table, :account, index: true }
    remove_column :users, :role
    remove_reference :users, :account, index: true
    drop_table :accounts
  end
end
