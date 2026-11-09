class NextTaskTool < MCP::Tool
  tool_name "next_task"
  description "Oldest actionable task in this agent's inbox. Waits up to 45 seconds; wait 0 checks at once."
  input_schema(
    properties: {
      wait: { type: "integer", description: "Seconds to wait for a task (0-45, default 45)." }
    }
  )
  output_schema(ConcourseMcp::Schemas::NEXT_TASK)
  annotations(title: "Next task", read_only_hint: true, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

  def self.call(server_context:, wait: nil)
    agent = ConcourseMcp.agent_from(server_context)
    payload = if wait.nil?
      A2a::Exchange.next_task_payload(agent)
    else
      A2a::Exchange.with_limits(inbox: coerce_wait(wait)) { A2a::Exchange.next_task_payload(agent) }
    end
    ConcourseMcp.result(payload)
  rescue A2a::Error => error
    ConcourseMcp.failure(error)
  end

  # Same cap as GET /api/next_task: the wait may only shorten the
  # 45 second cap, never outlive it. Non-integers are invalid_params.
  def self.coerce_wait(value)
    raise A2a::Error.new(:invalid_params) unless value.is_a?(Integer) && value.between?(0, A2a::Exchange::INBOX_WAIT)

    value
  end
  private_class_method :coerce_wait
end
