class AddTaskStatusTracking < ActiveRecord::Migration[8.1]
  def change
    # ListTasks orders and filters on the status timestamp (§3.1.4), which is
    # not the same clock as updated_at: a later message must not move a task
    # ahead of one whose status actually changed.
    add_column :tasks, :status_at, :datetime, null: false, default: -> { "CURRENT_TIMESTAMP" }
    add_column :tasks, :status_message_id, :string
    add_index :tasks, [ :status_at, :id ]

    add_column :messages, :extensions, :json, null: false, default: []
    add_column :messages, :reference_task_ids, :json, null: false, default: []
  end
end
