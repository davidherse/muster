class RenamePlanAttachmentToPlans < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE active_storage_attachments SET name = 'plans' WHERE name = 'plan' AND record_type = 'Estimate'"
  end

  def down
    execute "UPDATE active_storage_attachments SET name = 'plan' WHERE name = 'plans' AND record_type = 'Estimate'"
  end
end
