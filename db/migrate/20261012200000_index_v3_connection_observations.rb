class IndexV3ConnectionObservations < ActiveRecord::Migration[8.2]
  def change
    add_index :agent_connections, [ :organization_id, :agent_id, :observed_at ], name: "index_connections_on_recent_observation"
    add_index :agent_connections, [ :organization_id, :agent_id, :closed_at, :lease_expires_at ], name: "index_connections_on_live_lease"
  end
end
