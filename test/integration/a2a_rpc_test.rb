require "test_helper"

class A2aRpcTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @other = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ Organization.default ])
    @caller = Agent.create!(owner: @owner, handle: "codex", oauth_client_id: "client-a")
    @recipient = Agent.create!(owner: @other, handle: "pi", oauth_client_id: "client-b")
    @stranger = Agent.create!(owner: @owner, handle: "other", oauth_client_id: "client-c")
    @secret = "secret-text-#{SecureRandom.hex(8)}"
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      stub_agent_token("token-b", client_id: "client-b", sub: "7")
      stub_agent_token("token-c", client_id: "client-c", sub: "42")
    end
  end

  test "a missing token is 401 and never creates a task" do
    post "/a2a/riley/pi", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :unauthorized
    assert_not_includes response.headers["WWW-Authenticate"], "invalid_token"
    assert_equal 0, Task.count
  end

  test "the caller is the token's agent, not anything in the payload" do
    with_memory_cache do
      body = rpc(
        owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
        params: message_params("please look", message_id: "m-1").merge("sender" => "client-c")
      )

      task = Task.find(body.dig("result", "task", "id"))
      assert_equal @caller.id, task.caller_agent_id
      assert_equal @recipient.id, task.recipient_agent_id
      assert_equal "ROLE_USER", task.messages.sole.role
      assert_equal @caller.id, task.messages.sole.sender_agent_id
    end
  end

  test "client-supplied concourse metadata is dropped and the inbox caller is the token" do
    with_memory_cache do
      params = message_params("look", message_id: "m-meta")
      params["message"]["metadata"] = {
        "concourse.caller" => "riley/forged",
        "concourse.note" => "no",
        "ticket" => "AIG-1"
      }
      body = rpc(owner: "riley", agent: "pi", token: "token-a", method: "SendMessage", params: params)
      task = Task.find(body.dig("result", "task", "id"))

      assert_equal({ "ticket" => "AIG-1" }, task.messages.sole.metadata)
      assert_equal "AIG-1", body.dig("result", "task", "history", 0, "metadata", "ticket")
      assert_nil body.dig("result", "task", "history", 0, "metadata", "concourse.caller")

      get worker_inbox_path(@recipient), headers: { "Authorization" => "Bearer token-b" }
      listed = response.parsed_body.dig("tasks", 0)
      assert_equal "ajay/codex", listed.dig("metadata", "concourse.caller")
      assert_equal "ajay/codex", listed.dig("history", 0, "metadata", "concourse.caller")
      assert_equal "AIG-1", listed.dig("history", 0, "metadata", "ticket")
      assert_nil listed.dig("history", 0, "metadata", "concourse.note")
    end
  end

  test "returnImmediately returns the submitted task without waiting" do
    with_memory_cache do
      A2a::Exchange.with_limits(blocking: 30) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        body = rpc(
          owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
          params: message_params("now", message_id: "m-imm", configuration: { "returnImmediately" => true })
        )
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        # Nobody answers, so a blocking request would exhaust the whole 30
        # seconds. Half the limit leaves room for a loaded parallel run.
        assert_operator elapsed, :<, A2a::Exchange.blocking_limit / 2
        assert_equal "TASK_STATE_SUBMITTED", body.dig("result", "task", "status", "state")
        assert_not body.dig("result", "task", "status").key?("message")
        assert_nil body.dig("result", "task", "metadata")
      end
    end
  end

  test "a blocking send returns at a terminal state, and the 85 second cap errors without canceling work" do
    with_memory_cache do
      previous = A2a::Inbound.handler
      begin
        A2a::Inbound.handler = ->(task) { task.transition_to!("TASK_STATE_COMPLETED", by: task.recipient_agent) }
        A2a::Exchange.with_limits(blocking: 1) do
          body = rpc(
            owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
            params: message_params("block", message_id: "m-block", configuration: {})
          )
          assert_equal "TASK_STATE_COMPLETED", body.dig("result", "task", "status", "state")
        end
      ensure
        A2a::Inbound.handler = previous
      end

      capture_events("concourse.a2a.blocking_cap") do |events|
        A2a::Exchange.with_limits(blocking: 0) do
          body = rpc(
            owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
            params: message_params("capped", message_id: "m-cap", configuration: { "returnImmediately" => false })
          )
          # §3.2.2 requires terminal/interrupted settlement, not elapsed time.
          assert_nil body["result"]
          assert_equal(-32603, body.dig("error", "code"))
          info = body.fetch("error").fetch("data").sole
          assert_equal "type.googleapis.com/google.rpc.ErrorInfo", info["@type"]
          assert_equal "RELAY_WAIT_LIMIT", info["reason"]
          assert_equal "concourse.example.com", info["domain"]
          task = Task.find(info.fetch("metadata").fetch("taskId"))
          assert_equal "TASK_STATE_SUBMITTED", task.state
          assert task.actionable?
          assert_equal 1, task.messages.count
          fetched = rpc(owner: "riley", agent: "pi", token: "token-a", method: "GetTask", params: { "id" => task.id })
          assert_equal task.id, fetched.dig("result", "id")
          assert_equal "TASK_STATE_SUBMITTED", fetched.dig("result", "status", "state")
          retry_body = rpc(owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
            params: message_params("capped", message_id: "m-cap", configuration: { "returnImmediately" => true }))
          assert_equal task.id, retry_body.dig("result", "task", "id")
          assert_equal 1, task.reload.messages.count
          assert_equal 2, Task.count
        end
        assert_equal 1, events.size
        assert_equal 0, events.first[:payload][:limit_seconds]
        assert_not events.first.inspect.include?("capped")
      end
    end
  end

  test "an unsupported version is the section 3.6 error, including when the header is absent" do
    with_memory_cache do
      absent = rpc(owner: "riley", agent: "pi", token: "token-a", method: "GetTask", params: { "id" => "missing" }, version: nil)
      assert_equal(-32009, absent.dig("error", "code"))

      patch = rpc(owner: "riley", agent: "pi", token: "token-a", method: "GetTask", params: { "id" => "missing" }, version: "1.0.9")
      assert_equal(-32001, patch.dig("error", "code"))

      future = rpc(owner: "riley", agent: "pi", token: "token-a", method: "SendMessage", params: message_params("x", message_id: "m-ver"), version: "99.0")
      assert_equal(-32009, future.dig("error", "code"))
    end
  end

  test "push methods return the section 3.3.4 error, for a missing agent too" do
    with_memory_cache do
      missing = rpc(owner: "nobody", agent: "nope", token: "token-a", method: "CreateTaskPushNotificationConfig", params: { "taskId" => "t", "url" => "https://example.test" })
      assert_equal(-32003, missing.dig("error", "code"))

      push = rpc(owner: "riley", agent: "pi", token: "token-a", method: "CreateTaskPushNotificationConfig", params: { "taskId" => "missing", "url" => "https://example.test" })
      assert_equal(-32003, push.dig("error", "code"))
    end
  end

  test "parse, method, and parameter errors use the JSON-RPC codes" do
    with_memory_cache do
      post "/a2a/riley/pi", params: "{", headers: auth_headers
      assert_equal(-32700, response.parsed_body.dig("error", "code"))

      body = rpc(owner: "riley", agent: "pi", token: "token-a", method: "Nope", params: {})
      assert_equal(-32601, body.dig("error", "code"))

      bad = rpc(owner: "riley", agent: "pi", token: "token-a", method: "SendMessage", params: {})
      assert_equal(-32602, bad.dig("error", "code"))
    end
  end

  test "a blocking continuation waits until the recipient acts after the new message" do
    with_memory_cache do
      created = rpc(
        owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
        params: message_params("ask", message_id: "m-cont", configuration: { "returnImmediately" => true })
      )
      id = created.dig("result", "task", "id")
      Task.find(id).transition_to!("TASK_STATE_INPUT_REQUIRED", by: @recipient)

      A2a::Exchange.with_limits(blocking: 0.4, poll: 0.05) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stale = rpc(
          owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
          params: message_params("not yet", message_id: "m-cont-stale", configuration: {}, task_id: id)
        )
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :>, 0.3
        assert_nil stale["result"]
        assert_equal "RELAY_WAIT_LIMIT", stale.dig("error", "data", 0, "reason")
        assert_equal id, stale.dig("error", "data", 0, "metadata", "taskId")
        assert_equal "TASK_STATE_INPUT_REQUIRED", Task.find(id).state
      end

      A2a::Exchange.with_limits(blocking: 2, poll: 0.05) do
        finisher = Thread.new do
          sleep 0.25
          Task.find(id).transition_to!("TASK_STATE_COMPLETED", by: Agent.find(@recipient.id))
        end
        body = rpc(
          owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
          params: message_params("the file", message_id: "m-cont-2", configuration: {}, task_id: id)
        )
        finisher.join
        assert_equal "TASK_STATE_COMPLETED", body.dig("result", "task", "status", "state")
      end
    end
  end

  test "continuing a finished task names the reason and creates nothing" do
    with_memory_cache do
      created = rpc(
        owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
        params: message_params("ask", message_id: "m-done", configuration: { "returnImmediately" => true })
      )
      id = created.dig("result", "task", "id")
      Task.find(id).transition_to!("TASK_STATE_COMPLETED", by: @recipient)

      assert_no_difference [ -> { Task.count }, -> { Message.count } ] do
        body = rpc(
          owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
          params: message_params("one more thing", message_id: "m-done-2", task_id: id)
        )
        assert_nil body["result"]
        assert_equal(-32004, body.dig("error", "code"))
        assert_equal [ [ "UNSUPPORTED_OPERATION", "a2a-protocol.org" ], [ "TASK_TERMINAL", "concourse.krishnan.ca" ] ],
          body.dig("error", "data").map { |info| info.values_at("reason", "domain") }
        assert_match "start a new task", body.dig("error", "message")

        # The reason is for participants: anyone else still learns nothing (§13.1).
        stranger = rpc(
          owner: "riley", agent: "pi", token: "token-c", method: "SendMessage",
          params: message_params("let me in", message_id: "m-done-3", task_id: id)
        )
        assert_equal(-32001, stranger.dig("error", "code"))
        assert_not_includes stranger.to_json, "TASK_TERMINAL"
      end

      replied = A2a::Exchange.new(@recipient)
      error = assert_raises(A2a::Error) { replied.reply(id, state: "TASK_STATE_WORKING", parts: [ { "text" => "late" } ]) }
      assert_equal "TASK_TERMINAL", error.data.last["reason"]
    end
  end

  test "messageId idempotency is scoped to the caller" do
    with_memory_cache do
      first = rpc(
        owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
        params: message_params("one", message_id: "shared-id", configuration: { "returnImmediately" => true })
      )
      again = rpc(
        owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
        params: message_params("one", message_id: "shared-id", configuration: { "returnImmediately" => true })
      )
      other = rpc(
        owner: "riley", agent: "pi", token: "token-c", method: "SendMessage",
        params: message_params("two", message_id: "shared-id", configuration: { "returnImmediately" => true })
      )

      assert_equal first.dig("result", "task", "id"), again.dig("result", "task", "id")
      assert_nil other["error"]
      assert_not_equal first.dig("result", "task", "id"), other.dig("result", "task", "id")
      assert_equal "shared-id", other.dig("result", "task", "history", 0, "messageId")
    end
  end

  test "a wrong HTTP content type stays content-type-not-supported" do
    with_memory_cache do
      body = rpc(
        owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
        params: message_params("x", message_id: "m-ct"), content_type: "text/plain"
      )
      assert_equal(-32005, body.dig("error", "code"))
    end
  end

  test "a task the caller is not party to is the same error as a missing task, without its text" do
    hidden = Task.open!(recipient: @stranger, caller: @stranger)
    Message.record!(task: hidden, role: "ROLE_USER", sender: @stranger, parts: [ { "text" => @secret } ])

    with_memory_cache do
      missing = rpc(owner: "riley", agent: "pi", token: "token-a", method: "GetTask", params: { "id" => "no-such-task" })
      hidden_body = rpc(owner: "riley", agent: "pi", token: "token-a", method: "GetTask", params: { "id" => hidden.id })
      unknown_agent = rpc(owner: "nobody", agent: "ghost", token: "token-a", method: "GetTask", params: { "id" => hidden.id })

      assert_equal(-32001, missing.dig("error", "code"))
      assert_equal missing["error"], hidden_body["error"]
      assert_equal(-32001, unknown_agent.dig("error", "code"))
      assert_not response.body.include?(@secret)
    end
  end

  test "historyLength, includeArtifacts, and page tokens follow the spec" do
    with_memory_cache do
      first = rpc(owner: "riley", agent: "pi", token: "token-a", method: "SendMessage", params: message_params("one", message_id: "m-page-1", configuration: { "returnImmediately" => true }))
      context_id = first.dig("result", "task", "contextId")
      rpc(owner: "riley", agent: "pi", token: "token-a", method: "SendMessage", params: message_params("two", message_id: "m-page-2", context_id: context_id, configuration: { "returnImmediately" => true }))
      Task.order(:created_at).first.update!(status_at: 2.minutes.ago)

      zero = rpc(owner: "riley", agent: "pi", token: "token-a", method: "GetTask", params: { "id" => first.dig("result", "task", "id"), "historyLength" => 0 })
      assert_not zero.dig("result").key?("history")

      listed = rpc(owner: "riley", agent: "pi", token: "token-a", method: "ListTasks", params: { "pageSize" => 1, "includeArtifacts" => false })
      assert_equal 1, listed.dig("result", "tasks").size
      assert_equal 2, listed.dig("result", "totalSize")
      assert_not listed.dig("result", "tasks", 0).key?("artifacts")
      assert listed.dig("result", "nextPageToken").present?

      next_page = rpc(owner: "riley", agent: "pi", token: "token-a", method: "ListTasks", params: { "pageSize" => 1, "pageToken" => listed.dig("result", "nextPageToken") })
      assert_equal "", next_page.dig("result", "nextPageToken")
      assert_not_equal listed.dig("result", "tasks", 0, "id"), next_page.dig("result", "tasks", 0, "id")
    end
  end

  test "only the caller may cancel, and a terminal task is not cancelable" do
    with_memory_cache do
      created = rpc(owner: "riley", agent: "pi", token: "token-a", method: "SendMessage", params: message_params("cancel me", message_id: "m-cancel", configuration: { "returnImmediately" => true }))
      id = created.dig("result", "task", "id")

      stranger = rpc(owner: "riley", agent: "pi", token: "token-c", method: "CancelTask", params: { "id" => id })
      assert_equal(-32001, stranger.dig("error", "code"))

      recipient = rpc(owner: "riley", agent: "pi", token: "token-b", method: "CancelTask", params: { "id" => id })
      assert_equal(-32002, recipient.dig("error", "code"))

      canceled = rpc(owner: "riley", agent: "pi", token: "token-a", method: "CancelTask", params: { "id" => id })
      assert_equal "TASK_STATE_CANCELED", canceled.dig("result", "status", "state")

      again = rpc(owner: "riley", agent: "pi", token: "token-a", method: "CancelTask", params: { "id" => id })
      assert_equal "TASK_STATE_CANCELED", again.dig("result", "status", "state")
    end
  end

  test "the extended card requires a token and adds what the public card omits" do
    @recipient.update!(description: "Works the inbox.", skills: [ { "id" => "inbox", "name" => "Inbox", "description" => "Reads tasks.", "tags" => [ "tasks" ] } ], harness: "pi")
    get "/a2a/riley/pi/.well-known/agent-card.json"
    assert_response :success
    assert_equal "An agent registered on Concourse.", response.parsed_body["description"]

    with_memory_cache do
      body = rpc(owner: "riley", agent: "pi", token: "token-a", method: "GetExtendedAgentCard", params: {})
      card = body["result"]
      assert_equal "Works the inbox.", card["description"]
      extension = card.dig("capabilities", "extensions").find { |e| e["params"]&.key?("owner") }
      assert_equal "riley", extension.dig("params", "owner")
      assert_equal "pi", extension.dig("params", "harness")
      # The official SDKs parse the card strictly against the AgentCard proto.
      assert_empty card.keys - AGENT_CARD_FIELDS
      assert_equal "inbox", card.dig("skills", 0, "id")
    end
  end

  private

  AGENT_CARD_FIELDS = %w[name description supportedInterfaces provider version documentationUrl capabilities
    securitySchemes securityRequirements defaultInputModes defaultOutputModes skills signatures iconUrl].freeze

  def auth_headers
    { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer token-a", "A2A-Version" => "1.0" }
  end

  def message_params(text, message_id:, context_id: nil, task_id: nil, configuration: { "returnImmediately" => true })
    message = {
      "role" => "ROLE_USER",
      "parts" => [ { "text" => text } ],
      "messageId" => message_id
    }
    message["contextId"] = context_id if context_id
    message["taskId"] = task_id if task_id
    { "message" => message, "configuration" => configuration }
  end
end
