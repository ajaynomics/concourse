class MoveConformanceToPlatformOrganization < ActiveRecord::Migration[8.2]
  # The default organization used to be whichever one came first, a customer
  # in production. It is now the platform's own. The system user and
  # concourse/conformance move into it and leave every other organization.
  # An agent with tasks stays where it is: a task never spans two.
  def up
    slug = Rails.app.creds.option(:concourse, :default_organization).presence || "concourse"
    organizations = Class.new(ActiveRecord::Base) { self.table_name = "organizations" }
    users = Class.new(ActiveRecord::Base) { self.table_name = "users" }
    system = users.find_by(handle: "concourse", ajent_sub: nil)
    return unless system

    platform = organizations.find_or_create_by!(slug: slug) { |organization| organization.name = slug.titleize }
    id = Integer(platform.id)
    system_id = Integer(system.id)
    execute <<~SQL
      INSERT INTO memberships (user_id, organization_id, role, created_at, updated_at)
      SELECT #{system_id}, #{id}, 'member', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      WHERE NOT EXISTS (SELECT 1 FROM memberships WHERE user_id = #{system_id} AND organization_id = #{id})
    SQL
    execute <<~SQL
      UPDATE agents SET organization_id = #{id}, updated_at = CURRENT_TIMESTAMP
      WHERE owner_id = #{system_id} AND organization_id <> #{id}
        AND NOT EXISTS (SELECT 1 FROM tasks WHERE tasks.caller_agent_id = agents.id OR tasks.recipient_agent_id = agents.id)
    SQL
    execute <<~SQL
      DELETE FROM participations
      WHERE agent_id IN (SELECT id FROM agents WHERE owner_id = #{system_id} AND organization_id = #{id})
        AND project_id IN (SELECT id FROM projects WHERE organization_id <> #{id})
    SQL
    execute <<~SQL
      DELETE FROM memberships
      WHERE user_id = #{system_id} AND organization_id <> #{id}
        AND organization_id NOT IN (SELECT organization_id FROM agents WHERE owner_id = #{system_id})
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
