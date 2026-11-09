class CreateNamespaces < ActiveRecord::Migration[8.2]
  def up
    create_table :namespaces do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end
    add_index :namespaces, :name, unique: true

    # Not add_reference(foreign_key: true): SQLite adds a foreign key by
    # rebuilding agents, and inside the migration transaction the rebuild's
    # DROP TABLE fires every ON DELETE that points at agents. On 2026-10-14 it
    # nullified production's client bindings and cascaded away connections and
    # deliveries. ADD COLUMN with REFERENCES adds the same constraint in place.
    execute "ALTER TABLE agents ADD COLUMN namespace_id integer REFERENCES namespaces(id)"
    add_index :agents, :namespace_id
    add_index :agents, %i[namespace_id handle], unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "dropping agents.namespace_id would rebuild agents; see up"
  end
end
