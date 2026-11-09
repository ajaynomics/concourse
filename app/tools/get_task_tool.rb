class GetTaskTool < MCP::Tool
  tool_name "get_task"
  description "Fetch a task this agent sent or received."
  input_schema(
    properties: {
      id: { type: "string" },
      history_length: { type: "integer" }
    },
    required: %w[id]
  )
  output_schema(ConcourseMcp::Schemas::TASK)
  annotations(title: "Get task", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:, id:, history_length: nil)
    task = A2a::Exchange.get_task(
      viewer: ConcourseMcp.agent_from(server_context),
      id: id,
      history_length: history_length
    )
    ConcourseMcp.result(task)
  rescue A2a::Error => error
    ConcourseMcp.failure(error)
  end
end
