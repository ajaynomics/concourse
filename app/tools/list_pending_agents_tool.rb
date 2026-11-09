class ListPendingAgentsTool < MCP::Tool
  tool_name "list_pending_agents"
  description "Owner only. List agents waiting for an owner of your organization to approve them, oldest first."
  input_schema(properties: {})
  output_schema(ConcourseMcp::Schemas::PENDING_AGENTS)
  annotations(title: "List pending agents", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:)
    ConcourseMcp.as_owner(server_context) do |authority|
      { "agents" => authority.pending_agents.map(&:pending_entry) }
    end
  end
end
