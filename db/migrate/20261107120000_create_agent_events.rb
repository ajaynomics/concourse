class CreateAgentEvents < ActiveRecord::Migration[8.2]
  def up
    # Plain ADD COLUMN: SQLite rebuilds agents for add_reference(foreign_key:),
    # which cascaded deletes in production on 2026-10-14 (see CreateNamespaces).
    # event_seq is the last sequence number given to this agent's log;
    # event_cursor is the highest one the agent has acknowledged.
    add_column :agents, :event_seq, :integer, null: false, default: 0
    add_column :agents, :event_cursor, :integer, null: false, default: 0

    # One row per thing a peer did that this agent should hear about. seq is
    # per agent and has no gaps until retention removes the oldest rows, so a
    # client can tell a purged range from a quiet one. Rows go with their
    # task, so the thirty-day retention already covers them.
    create_table :agent_events do |t|
      t.references :agent, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :task, type: :string, limit: 36, null: false, foreign_key: { on_delete: :cascade }
      t.integer :seq, null: false
      t.string :kind, null: false
      t.string :message_id
      t.string :artifact_id
      t.string :state
      t.datetime :created_at, null: false
    end
    add_index :agent_events, %i[agent_id seq], unique: true
  end

  # Removing these columns would rebuild agents in SQLite.
  def down
    raise ActiveRecord::IrreversibleMigration, "removing agents.event_seq would rebuild agents"
  end
end
