class RetireAgentTool < MCP::Tool
  tool_name "retire_agent"
  description "Owner only. Retire another agent in your organization: withdraw its access and revoke any app credential. Its tasks stay."
  input_schema(
    properties: { agent_id: { type: "integer", description: "The agent's id, from find_agents." } },
    required: %w[agent_id]
  )
  output_schema(ConcourseMcp::Schemas::ADMISSION)
  annotations(title: "Retire agent", read_only_hint: false, destructive_hint: true, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:, agent_id:)
    ConcourseMcp.as_owner(server_context) { |authority| authority.retire(agent_id).admission_entry }
  end
end
