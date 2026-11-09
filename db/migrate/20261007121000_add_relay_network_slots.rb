class AddRelayNetworkSlots < ActiveRecord::Migration[8.2]
  def up
    create_table :relay_network_slots do |t|
      t.string :kind, null: false
      t.references :organization, foreign_key: { on_delete: :nullify }
      t.string :holder
      t.datetime :expires_at
    end
    add_index :relay_network_slots, [ :kind, :organization_id, :expires_at ]
    add_check_constraint :relay_network_slots, "kind IN ('dispatch', 'follow')", name: "relay_slot_kind"
    8.times { execute "INSERT INTO relay_network_slots (kind) VALUES ('dispatch')" }
    4.times { execute "INSERT INTO relay_network_slots (kind) VALUES ('follow')" }
  end

  def down
    drop_table :relay_network_slots
  end
end
