require "test_helper"

class AgentJsonApiTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @other = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    @stranger_owner = User.create!(ajent_sub: "9", handle: "stefano", email: "stefano@example.com", organizations: [ Organization.default ])
    @caller = Agent.create!(owner: @owner, handle: "codex", oauth_client_id: "client-a")
    @recipient = Agent.create!(owner: @other, handle: "pi", oauth_client_id: "client-b")
    @stranger = Agent.create!(owner: @stranger_owner, handle: "claude", oauth_client_id: "client-c")
    @secret = "hidden-task-secret-#{SecureRandom.hex(4)}"
    @task = Task.open!(recipient: @recipient, caller: @caller, context_id: "ctx-visible")
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "work this" } ])
    @hidden = Task.open!(recipient: @stranger, caller: @stranger)
    Message.record!(task: @hidden, role: "ROLE_USER", sender: @stranger, parts: [ { "text" => @secret } ])
  end

  test "patch card claims a handle once and rejects an mcp audience" do
    unnamed = Agent.create!(owner: @owner, oauth_client_id: "client-new")
    body = {
      handle: "pi-main",
      name: "Pi",
      description: "On the fe branch.",
      skills: [ { id: "fe", name: "Frontend", description: "UI", tags: [ "ui" ] } ],
      harness: "pi"
    }

    with_memory_cache do
      stub_agent_token("token-new", client_id: "client-new", sub: "42")
      stub_agent_token("mcp-token", client_id: "client-new", sub: "42", resource: :mcp)

      patch api_card_path, params: body.to_json, headers: json_bearer("mcp-token")
      assert_mcp_audience_rejected

      patch api_card_path, params: "{", headers: json_bearer("token-new")
      assert_response :bad_request
      assert_nil unnamed.reload.handle

      patch api_card_path, params: body.to_json, headers: json_bearer("token-new")
      assert_response :success
      unnamed.reload
      assert_equal "ajay/pi-main", response.parsed_body["name"]
      assert_equal "On the fe branch.", response.parsed_body["description"]
      assert_equal "pi", response.parsed_body.dig("capabilities", "extensions", 0, "params", "harness")
      assert_equal A2a::Card.extended_for(unnamed)["skills"], response.parsed_body["skills"]

      patch api_card_path, params: { handle: "other" }.to_json, headers: json_bearer("token-new")
      assert_response :unprocessable_entity
      assert_equal "pi-main", unnamed.reload.handle
      assert_equal({ "error" => "invalid_params" }, response.parsed_body)
    end
  end

  test "get task is party-to only and 404 does not disclose another agent's task" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      stub_agent_token("token-b", client_id: "client-b", sub: "7")
      stub_agent_token("mcp-token", client_id: "client-a", sub: "42", resource: :mcp)

      get api_task_path(@task), headers: bearer("mcp-token")
      assert_mcp_audience_rejected

      get api_task_path(@task), params: { historyLength: 0 }, headers: bearer("token-a")
      assert_response :success
      assert_equal @task.id, response.parsed_body["id"]
      assert_not response.parsed_body.key?("history")

      get api_task_path(@task), params: { history_length: 1 }, headers: bearer("token-b")
      assert_response :success
      assert_equal "work this", response.parsed_body.dig("history", 0, "parts", 0, "text")

      get api_task_path("missing-task"), headers: bearer("token-a")
      missing = response.body
      assert_response :not_found

      get api_task_path(@hidden), headers: bearer("token-a")
      assert_response :not_found
      assert_equal missing, response.body
      assert_not response.body.include?(@secret)

      get api_task_path(@hidden), params: { historyLength: "-1" }, headers: bearer("token-a")
      assert_response :unprocessable_entity
      assert_not response.body.include?(@secret)
    end
  end

  test "list tasks uses ListTasks filters and pagination and hides other agents" do
    older = Task.open!(recipient: @recipient, caller: @caller, context_id: "ctx-older")
    Message.record!(task: older, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "older work" } ])
    Artifact.record!(task: @task, by: @recipient, parts: [ { "text" => "result" } ], name: "out")
    older.update!(status_at: 2.minutes.ago)
    @task.update!(status_at: 1.minute.ago)

    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      stub_agent_token("mcp-token", client_id: "client-a", sub: "42", resource: :mcp)

      get api_tasks_path, headers: bearer("mcp-token")
      assert_mcp_audience_rejected

      get api_tasks_path, params: { pageSize: "1", includeArtifacts: "false", contextId: "ctx-visible" }, headers: bearer("token-a")
      assert_response :success
      assert_equal [ @task.id ], response.parsed_body["tasks"].map { |task| task["id"] }
      assert_equal 1, response.parsed_body["totalSize"]
      assert_equal 1, response.parsed_body["pageSize"]
      assert_not response.parsed_body.dig("tasks", 0).key?("artifacts")
      assert_not response.body.include?(@secret)

      get api_tasks_path, params: { page_size: "1", context_id: "ctx-visible" }, headers: bearer("token-a")
      assert_response :success
      assert_equal @task.id, response.parsed_body.dig("tasks", 0, "id")

      get api_tasks_path, params: { pageSize: "1" }, headers: bearer("token-a")
      assert_response :success
      assert_equal 2, response.parsed_body["totalSize"]
      token = response.parsed_body["nextPageToken"]
      assert token.present?
      first_id = response.parsed_body.dig("tasks", 0, "id")

      get api_tasks_path, params: { pageSize: "1", pageToken: token }, headers: bearer("token-a")
      assert_response :success
      assert_equal "", response.parsed_body["nextPageToken"]
      assert_not_equal first_id, response.parsed_body.dig("tasks", 0, "id")
      assert_not response.parsed_body["tasks"].map { |task| task["id"] }.include?(@hidden.id)

      get api_tasks_path, params: { status: "TASK_STATE_WORKING" }, headers: bearer("token-a")
      assert_response :success
      assert_empty response.parsed_body["tasks"]

      get api_tasks_path, params: { pageSize: "0" }, headers: bearer("token-a")
      assert_response :unprocessable_entity
      assert_equal({ "error" => "invalid_params" }, response.parsed_body)

      get api_tasks_path, params: { pageSize: "1", page_size: "2" }, headers: bearer("token-a")
      assert_response :unprocessable_entity
    end
  end

  test "next_task uses the shared payload, the 45 second cap, and the waiter cap" do
    assert_equal 45, A2a::Exchange::INBOX_WAIT

    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      stub_agent_token("token-b", client_id: "client-b", sub: "7")
      stub_agent_token("mcp-token", client_id: "client-b", sub: "7", resource: :mcp)

      get api_next_task_path, headers: bearer("mcp-token")
      assert_mcp_audience_rejected

      get api_next_task_path, params: { wait: "0" }, headers: bearer("token-a")
      assert_response :success
      assert_nil response.parsed_body["task"]

      get api_next_task_path, params: { wait: "0" }, headers: bearer("token-b")
      assert_response :success
      assert_equal @task.id, response.parsed_body.dig("task", "id")
      assert_equal "ajay/codex", response.parsed_body.dig("task", "metadata", "concourse.caller")
      assert_equal A2a::Exchange.next_task_payload(@recipient).dig("task", "id"), response.parsed_body.dig("task", "id")

      get api_next_task_path, params: { wait: "46" }, headers: bearer("token-b")
      assert_response :unprocessable_entity

      A2a::Waiters.limit = 0
      A2a::Waiters.reset!
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      capture_events("concourse.a2a.waiter_cap") do |events|
        get api_next_task_path, headers: bearer("token-a")
        assert_response :success
        assert_nil response.parsed_body["task"]
        assert_equal [ "next_task" ], events.map { |event| event.dig(:payload, :kind) }
        assert events.none? { |event| event.inspect.include?("work this") }
      end
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
    end
  ensure
    A2a::Waiters.limit = nil
    A2a::Waiters.reset!
  end

  private

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def json_bearer(token)
    bearer(token).merge("CONTENT_TYPE" => "application/json")
  end

  def assert_mcp_audience_rejected
    assert_response :unauthorized
    header = response.headers["WWW-Authenticate"]
    assert_includes header, %(resource_metadata="#{Concourse.app_url}/.well-known/oauth-protected-resource")
    assert_not_includes header, "/oauth-protected-resource/mcp"
    assert_includes header, %(error="invalid_token")
  end
end
