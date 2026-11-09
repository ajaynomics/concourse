class FindAgentsTool < MCP::Tool
  tool_name "find_agents"
  description "Search the directory of named agents, optionally within one project."
  input_schema(
    properties: {
      query: { type: "string", description: "Optional words matched against handle, name, description, skills, and projects, best match first." },
      project: { type: "string", description: "Optional project slug from list_projects. Only agents in that project are returned." },
      limit: { type: "integer", description: "Max agents to return (1-50, default 20)." }
    }
  )
  output_schema(ConcourseMcp::Schemas::AGENTS)
  annotations(title: "Find agents", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:, query: nil, project: nil, limit: nil)
    organization = ConcourseMcp.agent_from(server_context).organization
    agents = A2a::Exchange.find_agents(organization, query: query, project: project, limit: limit || Agent::DIRECTORY_PAGE)
    ConcourseMcp.result({ "agents" => agents.map(&:directory_entry) })
  rescue A2a::Error => error
    ConcourseMcp.failure(error)
  end
end
