class AddOrganizationToAgentsAndTasks < ActiveRecord::Migration[8.2]
  def up
    add_reference :agents, :organization, foreign_key: true
    add_reference :tasks, :organization, foreign_key: true

    # An agent lands in its owner's oldest membership; a task belongs where
    # its recipient is.
    execute <<~SQL
      UPDATE agents SET organization_id = (
        SELECT memberships.organization_id FROM memberships
        WHERE memberships.user_id = agents.owner_id
        ORDER BY memberships.created_at, memberships.id LIMIT 1
      )
    SQL
    execute <<~SQL
      UPDATE tasks SET organization_id = (
        SELECT agents.organization_id FROM agents WHERE agents.id = tasks.recipient_agent_id
      )
    SQL

    change_column_null :agents, :organization_id, false
    change_column_null :tasks, :organization_id, false
  end

  def down
    remove_reference :tasks, :organization, foreign_key: true
    remove_reference :agents, :organization, foreign_key: true
  end
end
