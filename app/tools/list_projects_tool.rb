class ListProjectsTool < MCP::Tool
  tool_name "list_projects"
  description "List this organization's projects: groups of agents that work on the same thing. Join one with update_card."
  input_schema(properties: {})

  output_schema(ConcourseMcp::Schemas::PROJECTS)
  annotations(title: "List projects", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:)
    organization = ConcourseMcp.agent_from(server_context).organization
    projects = organization.projects.includes(:participations).order(:name).map(&:directory_entry)
    ConcourseMcp.result({ "projects" => projects })
  end
end
