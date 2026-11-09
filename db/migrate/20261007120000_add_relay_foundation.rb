class AddRelayFoundation < ActiveRecord::Migration[8.2]
  def change
    change_table :agents do |t|
      t.string :native_endpoint_url
      t.string :native_card_url
      t.string :native_resource
      t.string :native_tenant
      t.integer :native_generation, default: 0, null: false
      t.boolean :native_enabled, default: false, null: false
      t.boolean :native_discoverable, default: false, null: false
      t.datetime :native_verified_at
      t.json :native_verification, default: {}, null: false
    end

    add_column :tasks, :execution_route, :string, default: "inbox", null: false
    add_column :tasks, :content_changed_at, :datetime
    reversible do |dir|
      dir.up { execute "UPDATE tasks SET content_changed_at = updated_at" }
    end
    add_check_constraint :tasks, "execution_route IN ('inbox', 'native', 'held')", name: "tasks_execution_route"
    add_index :tasks, [ :execution_route, :content_changed_at ]

    create_table :relay_deliveries, id: :string, limit: 36 do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :caller_agent, null: false, foreign_key: { to_table: :agents }
      t.references :recipient_agent, null: false, foreign_key: { to_table: :agents }
      t.references :task, type: :string, foreign_key: { on_delete: :nullify }
      t.string :reserved_task_id, null: false
      t.string :public_task_id
      t.string :operation, null: false
      t.string :message_id_digest, null: false
      t.string :request_digest, null: false
      t.json :request_payload
      t.json :result_payload
      t.string :execution_route, null: false
      t.string :endpoint_url
      t.string :resource
      t.string :tenant
      t.integer :generation, default: 0, null: false
      t.string :phase, default: "reserved", null: false
      t.string :outcome
      t.string :holder
      t.integer :fence, default: 0, null: false
      t.datetime :deadline_at
      t.datetime :content_changed_at, null: false
      t.datetime :expired_at
      t.timestamps
      t.index [ :caller_agent_id, :message_id_digest ], unique: true, name: "index_relay_deliveries_on_caller_and_message_digest"
      t.index [ :phase, :deadline_at ]
      t.index :content_changed_at
      t.index :task_id, unique: true, where: "task_id IS NOT NULL AND phase IN ('reserved', 'sending')", name: "index_relay_deliveries_on_active_mutation"
      t.check_constraint "execution_route IN ('inbox', 'native')", name: "relay_deliveries_execution_route"
      t.check_constraint "phase IN ('reserved', 'sending', 'held', 'accepted', 'rejected')", name: "relay_deliveries_phase"
    end

    create_table :relay_tasks do |t|
      t.references :task, type: :string, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :organization, null: false, foreign_key: true
      t.references :caller_agent, null: false, foreign_key: { to_table: :agents }
      t.references :recipient_agent, null: false, foreign_key: { to_table: :agents }
      t.string :endpoint_url, null: false
      t.string :resource, null: false
      t.string :tenant
      t.integer :generation, null: false
      t.string :native_task_id, null: false
      t.string :native_context_id
      t.json :upstream_metadata, default: {}, null: false
      t.datetime :upstream_status_at
      t.datetime :observed_at
      t.datetime :changed_at
      t.string :snapshot_digest
      t.datetime :next_follow_at
      t.string :lease_holder
      t.datetime :lease_expires_at
      t.integer :fence, default: 0, null: false
      t.boolean :stale, default: false, null: false
      t.boolean :gap, default: true, null: false
      t.timestamps
      t.index [ :organization_id, :recipient_agent_id, :generation, :native_task_id ], unique: true, name: "index_relay_tasks_on_native_identity"
      t.index :next_follow_at
    end

    create_table :relay_contexts do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :caller_agent, null: false, foreign_key: { to_table: :agents }
      t.references :recipient_agent, null: false, foreign_key: { to_table: :agents }
      t.integer :generation, null: false
      t.string :public_context_id, null: false
      t.string :native_context_id
      t.datetime :content_changed_at, null: false
      t.timestamps
      t.index [ :organization_id, :caller_agent_id, :recipient_agent_id, :generation, :public_context_id ], unique: true, name: "index_relay_contexts_on_public_identity"
      t.index [ :organization_id, :caller_agent_id, :recipient_agent_id, :generation, :native_context_id ], unique: true, name: "index_relay_contexts_on_native_identity"
    end

    add_column :messages, :native_message_id, :string
    add_column :messages, :native_task_id, :string
    add_column :messages, :native_context_id, :string
    add_index :messages, [ :task_id, :role, :native_message_id ], unique: true
    add_column :artifacts, :native_artifact_id, :string
    add_column :artifacts, :metadata, :json, default: {}, null: false
    add_column :artifacts, :extensions, :json, default: [], null: false
    add_index :artifacts, [ :task_id, :native_artifact_id ], unique: true
    add_column :task_events, :kind, :string
    add_column :task_events, :payload, :json
    add_column :task_events, :upstream_timestamp, :string
  end
end
