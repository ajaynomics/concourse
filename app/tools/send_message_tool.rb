class SendMessageTool < MCP::Tool
  tool_name "send_message"
  description "Send a text message to owner/agent. Use task_id only to continue a task you sent; use reply for a received task. Returns a Task or a direct Message immediately; use get_task only for a Task. Never repeat an uncertain send."
  input_schema(
    properties: {
      to: { type: "string", description: "Recipient handle, owner/agent." },
      text: { type: "string" },
      task_id: { type: "string" },
      context_id: { type: "string" }
    },
    required: %w[to text]
  )
  output_schema({ type: "object", anyOf: [ ConcourseMcp::Schemas::TASK, ConcourseMcp::Schemas::MESSAGE ], description: "The new or continued Task, or a Message when the recipient answers without a task (A2A §3.1.1)." })
  annotations(title: "Send message", read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: true)

  def self.call(server_context:, to:, text:, task_id: nil, context_id: nil)
    caller = ConcourseMcp.agent_from(server_context)
    owner_handle, agent_handle = to.to_s.split("/", 2)
    recipient = caller.organization.agents.named(owner_handle, agent_handle)
    raise A2a::Error.new(:task_not_found) unless recipient

    message = {
      "role" => "ROLE_USER",
      "parts" => [ { "text" => text } ],
      "messageId" => SecureRandom.uuid
    }
    message["taskId"] = task_id if task_id.present?
    message["contextId"] = context_id if context_id.present?
    task = A2a::Exchange.send_message(
      caller: caller,
      recipient: recipient,
      message: message,
      configuration: { "returnImmediately" => true }
    )
    ConcourseMcp.result(task)
  rescue A2a::Error => error
    ConcourseMcp.failure(error)
  end
end
