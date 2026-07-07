class CreateCalibrationProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :calibration_profiles do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      # { "buckets" => { "<TradeBucket>" => { "bias_pct" => -20, "n" => 4 } }, ... }
      t.json :buckets, null: false, default: {}
      t.json :derived_from, null: false, default: []
      t.text :notes
      t.timestamps
    end
  end
end
