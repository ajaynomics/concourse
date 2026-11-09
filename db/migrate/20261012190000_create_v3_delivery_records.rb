class CreateV3DeliveryRecords < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_connections, id: :string do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      # Historical membership identity, deliberately not a FK: removal must
      # invalidate the connection without deleting its observation.
      t.integer :membership_id, null: false
      t.string :session_id, null: false, limit: 200
      t.datetime :observed_at, null: false
      t.datetime :lease_expires_at, null: false
      t.datetime :limit_at, null: false
      t.datetime :closed_at
      t.timestamps
      t.index [ :agent_id, :session_id ]
    end

    create_table :task_deliveries, id: :string do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :task, type: :string, null: false, foreign_key: { on_delete: :cascade }
      t.references :connection, type: :string, null: false, foreign_key: { to_table: :agent_connections }
      t.string :session_id, null: false
      t.string :phase, null: false, default: "queued"
      t.json :message_ids, null: false, default: []
      t.string :settlement_digest
      t.timestamps
      t.index :task_id, unique: true, where: "phase IN ('queued', 'prompting', 'running', 'uncertain')", name: "index_task_deliveries_on_unfinished_task"
      t.check_constraint "phase IN ('queued', 'prompting', 'running', 'uncertain', 'settled', 'canceled')", name: "task_deliveries_phase"
    end

    create_table :task_delivery_messages do |t|
      t.references :task_delivery, type: :string, null: false, foreign_key: { on_delete: :cascade }
      t.string :message_id, null: false
      t.index :message_id, unique: true
      t.foreign_key :messages, column: :message_id, primary_key: :message_id, on_delete: :cascade
    end
  end
end
