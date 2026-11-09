class ScopeAgentIdentityToOwner < ActiveRecord::Migration[8.1]
  def change
    remove_index :agents, name: "index_agents_on_oauth_client_id"
    add_index :agents, [ :owner_id, :oauth_client_id ], unique: true, name: "index_agents_on_owner_id_and_oauth_client_id"
  end
end
