class AddCalibrationFieldsToEstimatesAndProfiles < ActiveRecord::Migration[8.1]
  def change
    # links a calibration estimate back to the training upload it validates
    add_reference :estimates, :calibration_training_document, foreign_key: { to_table: :training_documents }, null: true
    # accumulated (ours, theirs) pairs the profile derives from
    add_column :calibration_profiles, :pairs, :json, null: false, default: []
  end
end
