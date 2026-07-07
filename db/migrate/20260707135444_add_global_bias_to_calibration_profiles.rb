class AddGlobalBiasToCalibrationProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :calibration_profiles, :global_bias_pct, :integer
  end
end
