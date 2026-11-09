class CreateTaskEvents < ActiveRecord::Migration[8.2]
  def change
    create_table :task_events do |t|
      t.references :task, type: :string, limit: 36, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :state
      t.string :status_message_id
      t.string :artifact_id
      t.datetime :created_at, null: false
    end
    add_index :task_events, %i[task_id id]
  end
end
