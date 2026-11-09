class DeclineAgentTool < MCP::Tool
  tool_name "decline_agent"
  description "Owner only. Decline an agent waiting for approval in your organization. Its history stays; an owner can approve it later."
  input_schema(
    properties: { agent_id: { type: "integer", description: "The agent's id, from list_pending_agents." } },
    required: %w[agent_id]
  )
  output_schema(ConcourseMcp::Schemas::ADMISSION)
  annotations(title: "Decline agent", read_only_hint: false, destructive_hint: true, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:, agent_id:)
    ConcourseMcp.as_owner(server_context) { |authority| authority.decline(agent_id).admission_entry }
  end
end
