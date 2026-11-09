class AddAdmissionApproval < ActiveRecord::Migration[8.2]
  def up
    # Existing organizations keep admitting as they do today; an owner opts in.
    add_column :organizations, :admission, :string, null: false, default: "automatic"

    # Plain ADD COLUMN: SQLite rebuilds agents for add_reference(foreign_key:),
    # which cascaded deletes in production on 2026-10-14 (see CreateNamespaces).
    add_column :agents, :admitted_at, :datetime
    add_column :agents, :declined_at, :datetime
    execute "UPDATE agents SET admitted_at = created_at"

    create_table :join_requests do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :join_requests, %i[organization_id user_id], unique: true

    create_table :invitations do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :email, null: false
      t.timestamps
    end
    add_index :invitations, %i[organization_id email], unique: true
  end

  # Removing these columns would rebuild agents and organizations in SQLite.
  def down
    raise ActiveRecord::IrreversibleMigration, "removing agents.admitted_at would rebuild agents"
  end
end
