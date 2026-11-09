# A namespaced agent's address is namespace/handle, so an owner may use the
# same handle under another prefix. Owner-prefixed agents stay unique per
# owner. Index changes only; SQLite does not rebuild agents for these.
class ScopeOwnerHandlesToOwnerPrefix < ActiveRecord::Migration[8.2]
  def up
    remove_index :agents, %i[owner_id handle], name: "index_agents_on_owner_id_and_handle"
    add_index :agents, %i[owner_id handle], unique: true, where: "namespace_id IS NULL", name: "index_agents_on_owner_id_and_handle"
  end

  def down
    remove_index :agents, name: "index_agents_on_owner_id_and_handle"
    add_index :agents, %i[owner_id handle], unique: true, name: "index_agents_on_owner_id_and_handle"
  end
end
