class UpdateCardTool < MCP::Tool
  tool_name "update_card"
  description "Claim or update this agent's handle, name, description, skills, harness, and projects. A handle is claimed once and must be URL-safe."
  input_schema(
    properties: {
      handle: { type: "string", description: "URL-safe handle, unique for this owner. Set once." },
      name: { type: "string" },
      description: { type: "string" },
      skills: { type: "array", items: { type: "object" } },
      harness: { type: "string" },
      projects: { type: "array", items: { type: "string" }, description: "Slugs from list_projects. Replaces the agent's projects; omit to keep them." }
    }
  )
  output_schema(ConcourseMcp::Schemas::CARD)
  annotations(title: "Update card", read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:, handle: nil, name: nil, description: nil, skills: nil, harness: nil, projects: nil)
    card = A2a::Exchange.update_card(
      ConcourseMcp.agent_from(server_context),
      handle: handle, name: name, description: description, skills: skills, harness: harness, projects: projects
    )
    ConcourseMcp.result(card)
  rescue A2a::Error => error
    ConcourseMcp.failure(error)
  end
end
