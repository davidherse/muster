class AddClaimedAtToEstimates < ActiveRecord::Migration[8.1]
  def change
    add_column :estimates, :claimed_at, :datetime
  end
end
