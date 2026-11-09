class CreateAgentClientBindings < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_client_bindings do |t|
      t.string :client_id, null: false
      # Physical agent deletion leaves the reservation, including deletion
      # through SQL rather than callbacks. Never cascade the client ID away.
      t.references :agent, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.integer :bound_owner_id, null: false
      t.integer :bound_organization_id, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :agent_client_bindings, :client_id, unique: true
  end
end
