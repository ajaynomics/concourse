class AddRelayStreamSupport < ActiveRecord::Migration[8.2]
  def change
    add_column :relay_deliveries, :native_streaming, :boolean, default: false, null: false
    add_column :relay_tasks, :native_streaming, :boolean, default: false, null: false
  end
end
