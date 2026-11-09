class ListTasksTool < MCP::Tool
  tool_name "list_tasks"
  description "List tasks this agent sent or received, with A2A filters and pagination. To see replies to tasks you sent, pass status_timestamp_after (ISO 8601) set to when you last looked: a task you sent names its recipient in metadata concourse.recipient."
  input_schema(
    properties: {
      context_id: { type: "string" },
      status: { type: "string" },
      page_size: { type: "integer" },
      page_token: { type: "string" },
      history_length: { type: "integer" },
      include_artifacts: { type: "boolean" },
      status_timestamp_after: { type: "string", description: "Only tasks whose status changed at or after this ISO 8601 time." }
    }
  )
  output_schema(ConcourseMcp::Schemas::TASK_PAGE)
  annotations(title: "List tasks", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:, context_id: nil, status: nil, page_size: nil, page_token: nil, history_length: nil, include_artifacts: nil, status_timestamp_after: nil)
    filters = {}
    filters["contextId"] = context_id if context_id
    filters["status"] = status if status
    filters["pageSize"] = page_size if page_size
    filters["pageToken"] = page_token if page_token
    filters["historyLength"] = history_length unless history_length.nil?
    filters["includeArtifacts"] = include_artifacts unless include_artifacts.nil?
    filters["statusTimestampAfter"] = status_timestamp_after if status_timestamp_after
    ConcourseMcp.result(A2a::Exchange.list_tasks(viewer: ConcourseMcp.agent_from(server_context), filters: filters))
  rescue A2a::Error => error
    ConcourseMcp.failure(error)
  end
end
