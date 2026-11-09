class AddNativeStatusEvidence < ActiveRecord::Migration[8.2]
  def change
    add_column :task_events, :settlement_evidence, :boolean, default: true, null: false
  end
end
