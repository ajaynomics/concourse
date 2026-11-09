class ApproveAgentTool < MCP::Tool
  tool_name "approve_agent"
  description "Owner only. Approve an agent in your organization that is waiting or was declined. Approving an approved agent changes nothing."
  input_schema(
    properties: { agent_id: { type: "integer", description: "The agent's id, from list_pending_agents." } },
    required: %w[agent_id]
  )
  output_schema(ConcourseMcp::Schemas::ADMISSION)
  annotations(title: "Approve agent", read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:, agent_id:)
    ConcourseMcp.as_owner(server_context) { |authority| authority.approve(agent_id).admission_entry }
  end
end
