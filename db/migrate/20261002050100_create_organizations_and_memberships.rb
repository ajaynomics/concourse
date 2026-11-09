class CreateOrganizationsAndMemberships < ActiveRecord::Migration[8.2]
  def up
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :email_domains
      t.timestamps
    end
    add_index :organizations, :slug, unique: true

    create_table :memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.string :role, null: false, default: "member"
      t.timestamps
    end
    add_index :memberships, %i[user_id organization_id], unique: true

    # Everyone already here was admitted before Concourse had organizations,
    # so they all start in the default one, the system user included.
    slug = Rails.app.creds.option(:concourse, :default_organization).presence || "default"
    organizations = Class.new(ActiveRecord::Base) { self.table_name = "organizations" }
    organization = organizations.create!(name: slug.titleize, slug: slug)
    execute <<~SQL
      INSERT INTO memberships (user_id, organization_id, role, created_at, updated_at)
      SELECT id, #{Integer(organization.id)}, 'member', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM users
    SQL
  end

  def down
    drop_table :memberships
    drop_table :organizations
  end
end
