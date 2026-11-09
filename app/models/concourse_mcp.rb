module ConcourseMcp
  # credential_subject: the person behind a human sign-in, nil for an app's
  # unattended credential. Only the former may act for the owner.
  Context = Data.define(:agent, :credential_subject) do
    def initialize(agent:, credential_subject: nil)
      super
    end
  end

  # The server's serverInfo. The Server Card repeats it, and SEP-2127 asks the
  # two not to contradict each other, so both read it from here.
  SERVER_INFO = { name: "concourse", title: "Concourse", version: "1.0.0" }.freeze

  def self.tools
    [
      UpdateCardTool,
      FindAgentsTool,
      ListProjectsTool,
      SendMessageTool,
      NextTaskTool,
      ReplyTool,
      GetTaskTool,
      ListTasksTool,
      ListPendingAgentsTool,
      ApproveAgentTool,
      DeclineAgentTool,
      RetireAgentTool
    ]
  end

  # A Message answer (A2A §3.1.1) is a DirectMessage struct; send its wire hash.
  def self.result(object)
    object = object.to_h if object.is_a?(A2a::DirectMessage)
    MCP::Tool::Response.new(
      [ { type: "text", text: JSON.generate(object) } ],
      structured_content: object
    )
  end

  def self.failure(error)
    body = { "code" => error.code, "message" => error.message }
    MCP::Tool::Response.new(
      [ { type: "text", text: JSON.generate(body) } ],
      error: true,
      structured_content: body
    )
  end

  def self.agent_from(server_context)
    server_context.agent
  end

  # Owner tools share Agent::OwnerAuthority, and its refusals, with REST.
  def self.as_owner(server_context)
    authority = Agent::OwnerAuthority.new(server_context.agent, credential_subject: server_context.credential_subject)
    result(yield(authority))
  rescue Agent::OwnerAuthority::Refusal => error
    refusal(error.code, error.message)
  rescue ActiveRecord::RecordNotFound
    refusal("not_found", "No such agent in this organization.")
  end

  # A plain code and message, not an A2A error.
  def self.refusal(code, message)
    body = { "code" => code, "message" => message }
    MCP::Tool::Response.new([ { type: "text", text: JSON.generate(body) } ], error: true, structured_content: body)
  end
end
