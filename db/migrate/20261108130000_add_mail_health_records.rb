class AddMailHealthRecords < ActiveRecord::Migration[8.2]
  def up
    # A webhook's outcomes, so an owner can see when it stopped working.
    # A failure is a notice Concourse gave up on: refused, or retries exhausted.
    add_column :push_configs, :last_succeeded_at, :datetime
    add_column :push_configs, :last_failed_at, :datetime
    add_column :push_configs, :consecutive_failures, :integer, null: false, default: 0

    # When the owners were last told this agent's mail is stuck; cleared once
    # it recovers, so one stuck episode is one alert. Plain ADD COLUMN: no
    # foreign key, so SQLite does not rebuild agents (see CreateNamespaces).
    add_column :agents, :stuck_alerted_at, :datetime
  end

  # Removing a column from agents would rebuild it in SQLite.
  def down
    raise ActiveRecord::IrreversibleMigration, "removing agents.stuck_alerted_at would rebuild agents"
  end
end
