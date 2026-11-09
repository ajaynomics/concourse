require "test_helper"

class A2aStreamingTest < ActionDispatch::IntegrationTest
  setup do
    owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    other = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    @caller = Agent.create!(owner: owner, handle: "codex", oauth_client_id: "client-a")
    @recipient = Agent.create!(owner: other, handle: "pi", oauth_client_id: "client-b")
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
    end
  end

  test "SendStreamingMessage answers with Server-Sent Events, each a JSON-RPC response with the request's id" do
    with_memory_cache do
      params = message_params("build it", message_id: "m-stream").merge("configuration" => { "returnImmediately" => false })
      events = stream("SendStreamingMessage", params, blocking: 0, heartbeat: 0.02, stream: 0.1)

      assert_equal "text/event-stream", response.media_type
      assert_equal "no-cache", response.headers["Cache-Control"]
      first = events.first
      assert_equal({ "jsonrpc" => "2.0", "id" => "req-1" }, first.slice("jsonrpc", "id"))
      task = Task.sole
      assert_equal task.id, first.dig("result", "task", "id")
      assert_equal "TASK_STATE_SUBMITTED", first.dig("result", "task", "status", "state")
      assert_includes response.body, "\n: keepalive\n\n"
      assert events.none? { |event| event.key?("error") }, "streaming does not use the blocking send limit"
    end
  end

  test "SubscribeToTask follows a task the caller can see until it is terminal" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "build it" } ])
    A2a::Exchange.new(@recipient).reply(task.id, state: "TASK_STATE_WORKING")

    with_memory_cache do
      events = stream("SubscribeToTask", { "id" => task.id }, stream: 0.05)
      assert_equal [ "TASK_STATE_WORKING" ], events.map { |event| event.dig("result", "task", "status", "state") }

      A2a::Exchange.new(@recipient).reply(task.id, state: "TASK_STATE_COMPLETED")
      terminal = rpc(owner: "riley", agent: "pi", token: "token-a", method: "SubscribeToTask", params: { "id" => task.id })
      assert_equal "application/json", response.media_type
      assert_equal(-32004, terminal.dig("error", "code"))
      assert_equal [ "UNSUPPORTED_OPERATION", "TASK_TERMINAL" ], terminal.dig("error", "data").map { |info| info["reason"] }
      assert_match "GetTask", terminal.dig("error", "message")

      missing = rpc(owner: "riley", agent: "pi", token: "token-a", method: "SubscribeToTask", params: { "id" => "nope" })
      assert_equal(-32001, missing.dig("error", "code"))

      nobody = rpc(owner: "nobody", agent: "nope", token: "token-a", method: "SubscribeToTask", params: { "id" => task.id })
      assert_equal(-32001, nobody.dig("error", "code"))
    end
  end

  test "an invalid streaming request is a plain JSON-RPC error and records nothing" do
    with_memory_cache do
      body = rpc(owner: "riley", agent: "pi", token: "token-a", method: "SendStreamingMessage", params: { "message" => { "role" => "ROLE_AGENT", "parts" => [ { "text" => "x" } ], "messageId" => "m" } })

      assert_equal "application/json", response.media_type
      assert_equal(-32602, body.dig("error", "code"))
      assert_equal 0, Task.count
    end
  end

  private

  def stream(method, params, **limits)
    A2a::Exchange.with_limits(poll: 0.01, **limits) do
      post "/a2a/#{Organization.default.slug}/riley/pi",
        params: { jsonrpc: "2.0", id: "req-1", method: method, params: params }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Accept" => "text/event-stream", "Authorization" => "Bearer token-a", "A2A-Version" => "1.0" }
    end
    response.body.scan(/^data: (.*)$/).map { |(data)| JSON.parse(data) }
  end

  def message_params(text, message_id:)
    { "message" => { "role" => "ROLE_USER", "parts" => [ { "text" => text } ], "messageId" => message_id } }
  end
end
