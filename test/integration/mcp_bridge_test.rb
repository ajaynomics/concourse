require "test_helper"

class McpBridgeTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @agent = Agent.create!(owner: @owner, oauth_client_id: "client-a")
  end

  # Falcon's request body reads once and does not rewind. Rails has read it
  # by the time the controller runs, to parse the JSON parameters.
  OneShotInput = Struct.new(:io) do
    def read(*args) = io.read(*args)
    def gets = io.gets
    def each(&) = io.each(&)
    def rewind = 0
    def close = nil
  end

  test "an initialize works when the request body cannot be read twice" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42", email: "ajay@example.com", resource: :mcp)
      body = { jsonrpc: "2.0", id: 1, method: "initialize",
               params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" } } }.to_json

      post "/mcp", headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json, text/event-stream", "Authorization" => "Bearer token-a" },
        env: { "rack.input" => OneShotInput.new(StringIO.new(body)), "CONTENT_LENGTH" => body.bytesize.to_s }

      assert_response :ok
      assert_equal "concourse", response.parsed_body.dig("result", "serverInfo", "name")
    end
  end

  test "tools run through /mcp and caller tools use the same operations" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42", email: "ajay@example.com", resource: :mcp)
      A2a::Exchange.with_limits(inbox: 0, blocking: 0) do
        claimed = mcp_call("token-a", "update_card", {
          "handle" => "codex",
          "name" => "Codex",
          "description" => "On the fe branch.",
          "skills" => [ { "id" => "fe", "name" => "Frontend", "description" => "UI", "tags" => [ "ui" ] } ],
          "harness" => "codex"
        })
        assert_equal "ajay/codex", claimed.dig("result", "structuredContent", "name")
        assert_equal "On the fe branch.", claimed.dig("result", "structuredContent", "description")

        again = mcp_call("token-a", "update_card", { "handle" => "other" })
        assert_equal true, again.dig("result", "isError")
        assert_equal "codex", @agent.reload.handle

        found = mcp_call("token-a", "find_agents", { "query" => "fe branch" })
        assert_equal [ "ajay/codex" ], found.dig("result", "structuredContent", "agents").map { |agent| agent["handle"] }

        other = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
        Agent.create!(owner: other, handle: "pi", oauth_client_id: "client-b", description: "inbox")
        sent = mcp_call("token-a", "send_message", { "to" => "riley/pi", "text" => "hello from mcp" })
        task_id = sent.dig("result", "structuredContent", "id")
        assert_equal "TASK_STATE_SUBMITTED", sent.dig("result", "structuredContent", "status", "state")
        assert_equal @agent.id, Task.find(task_id).caller_agent_id

        waiting = mcp_call("token-a", "next_task")
        assert_nil waiting.dig("result", "structuredContent", "task")

        fetched = mcp_call("token-a", "get_task", { "id" => task_id })
        assert_equal task_id, fetched.dig("result", "structuredContent", "id")
        assert fetched.dig("result", "content", 0, "text").include?(task_id)
      end
    end
  end

  test "production allows only the app host" do
    assert_equal [ URI(Concourse.app_url).host ], McpController.allowed_hosts(test: false)
    assert_includes McpController.allowed_hosts(test: true), "www.example.com"
  end

  test "mcp without a token is 401 pointing at the mcp resource metadata" do
    post "/mcp", params: "{}", headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], "/.well-known/oauth-protected-resource/mcp"
  end

  # MCP 2025-11-25 lifecycle and tools: a stateless bridge has no change stream.
  test "wire capabilities advertise only the implemented tool surface" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42", resource: :mcp)
      mcp_request("initialize", protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "contract", version: "1" })
      assert_response :ok
      assert_equal "2025-11-25", response.parsed_body.dig("result", "protocolVersion")
      assert_equal({ "tools" => {} }, response.parsed_body.dig("result", "capabilities"))
      mcp_request("tools/list")
      assert_response :ok
      tools = response.parsed_body.fetch("result").fetch("tools")
      assert_equal ConcourseMcp.tools.map(&:tool_name).sort, tools.pluck("name").sort
      assert tools.all? { |tool| tool.dig("outputSchema", "type") == "object" }
      assert_match(/Task or a direct Message/, tools.find { |tool| tool["name"] == "send_message" }.fetch("description"))
    end
  end

  test "wire notifications are accepted without a response and no GET subscription is offered" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42", resource: :mcp)
      post "/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json, headers: mcp_headers
      assert_response :accepted
      assert_empty response.body
      get "/mcp", headers: mcp_headers.merge("ACCEPT" => "text/event-stream")
      assert_response :method_not_allowed
    end
  end

  test "MCP wire refuses foreign Origin Host and the app audience" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42", resource: :mcp)
      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
        headers: mcp_headers.merge("Origin" => "https://foreign.example")
      assert_response :forbidden
      host! "foreign.example"
      mcp_request("tools/list")
      assert_response :forbidden
      host! "www.example.com"
      stub_agent_token("app-token", client_id: "client-a", sub: "42", resource: :app)
      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
        headers: mcp_headers.merge("Authorization" => "Bearer app-token")
      assert_response :unauthorized
    end
  end

  private

  def mcp_headers
    { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json", "Authorization" => "Bearer token-a" }
  end

  def mcp_request(method, **params)
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json, headers: mcp_headers
  end
end
