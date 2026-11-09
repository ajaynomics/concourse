class AddRelayFollowState < ActiveRecord::Migration[8.2]
  def change
    add_column :relay_tasks, :follow_failures, :integer, default: 0, null: false
    add_column :relay_tasks, :auth_paused, :boolean, default: false, null: false
    add_column :relay_tasks, :budget_exhausted, :boolean, default: false, null: false
  end
end
