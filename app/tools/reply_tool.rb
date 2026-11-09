class ReplyTool < MCP::Tool
  tool_name "reply"
  description "Add a message, change state, or attach an artifact on a task this agent receives."
  input_schema(
    properties: {
      task_id: { type: "string" },
      text: { type: "string" },
      state: { type: "string" },
      artifact_name: { type: "string" },
      artifact_text: { type: "string" },
      expected_caller_input: {
        type: "object",
        description: "Optional metadata.concourse.caller_input from the task read. Stale evidence refuses the entire reply; read the task again, never replay blindly.",
        properties: { cursor: { type: "string", pattern: "^[1-9][0-9]*$" }, messageId: { type: "string", minLength: 1 } },
        required: %w[cursor messageId],
        additionalProperties: false
      }
    },
    required: %w[task_id]
  )
  output_schema(ConcourseMcp::Schemas::TASK)
  annotations(title: "Reply", read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

  def self.call(server_context:, task_id:, text: nil, state: nil, artifact_name: nil, artifact_text: nil,
    expected_caller_input: A2a::Exchange::UNSPECIFIED_CALLER_INPUT)
    raise A2a::Error.new(:invalid_params) if text.blank? && state.blank? && artifact_text.blank?
    # The MCP SDK symbolizes nested JSON keys; Exchange consumes the wire shape.
    expected_caller_input = expected_caller_input.stringify_keys if expected_caller_input.is_a?(Hash)

    artifact = artifact_text.present? ? { parts: [ { "text" => artifact_text } ], name: artifact_name } : nil
    task = A2a::Exchange.reply(
      agent: ConcourseMcp.agent_from(server_context),
      task_id: task_id,
      parts: text.present? ? [ { "text" => text } ] : nil,
      state: state.presence,
      artifact: artifact,
      expected_caller_input: expected_caller_input
    )
    ConcourseMcp.result(A2a::Serializer.task(task, artifacts: :include))
  rescue A2a::Exchange::StaleReply
    # MCP tool errors are not HTTP conflicts or fabricated A2A Task outcomes.
    body = { "code" => "stale_reply", "message" => "stale_reply" }
    MCP::Tool::Response.new([ { type: "text", text: JSON.generate(body) } ], error: true, structured_content: body)
  rescue A2a::Error => error
    ConcourseMcp.failure(error)
  end
end
