class CreateEarlyAccessSignups < ActiveRecord::Migration[8.1]
  def change
    create_table :early_access_signups do |t|
      t.string :email, null: false, index: { unique: true }
      t.string :name
      t.string :company
      t.timestamps
    end
  end
end
