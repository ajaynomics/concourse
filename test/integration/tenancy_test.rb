require "test_helper"

# Two organizations on one Concourse. Nothing in one is reachable from the
# other: an id or a handle from the other side is simply not found.
class TenancyTest < ActionDispatch::IntegrationTest
  setup do
    @home = Organization.default
    @elsewhere = Organization.create!(name: "Elsewhere", email_domains: "elsewhere.test")
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ @home ])
    @riley = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ @home ])
    @sam = User.create!(ajent_sub: "9", handle: "sam", email: "sam@elsewhere.test", name: "Sam", organizations: [ @elsewhere ])
    @codex = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a")
    @pi = Agent.create!(owner: @riley, handle: "pi", oauth_client_id: "client-b")
    @hermes = Agent.create!(owner: @sam, handle: "hermes", oauth_client_id: "client-c")
    @task = Task.open!(recipient: @pi, caller: @codex)
    @their_task = Task.open!(recipient: @hermes, caller: @hermes)
  end

  test "the web shows one organization, and the other's ids are not found" do
    sign_in_via_ajent(subject: "9", email: "sam@elsewhere.test", name: "Sam")

    get agents_path(@elsewhere)
    assert_select "a[href='/elsewhere/agents/sam/hermes']"
    assert_select "a[href$='/agents/ajay/codex']", count: 0

    get agent_path(@elsewhere, "ajay", "codex")
    assert_response :not_found
    get my_task_path(@elsewhere, @task)
    assert_response :not_found
    get my_task_path(@elsewhere, @their_task)
    assert_response :success
  end

  test "an organization the person does not belong to is not found" do
    sign_in_via_ajent(subject: "9", email: "sam@elsewhere.test", name: "Sam")

    get organization_root_path(@home)
    assert_response :not_found
    get agents_path(@home)
    assert_response :not_found
    get my_task_path(@home, @their_task)
    assert_response :not_found
    assert_equal @elsewhere.id, session[:organization_id]
  end

  test "a person cannot act on another organization's task" do
    @elsewhere.memberships.create!(user: @riley)
    sign_in_via_ajent(subject: "7", email: "riley@example.com", name: "Riley")

    post my_task_response_path(@elsewhere, @task), params: { side: "recipient", text: "Done.", state: "TASK_STATE_COMPLETED" }
    assert_response :not_found
    post my_task_cancellation_path(@elsewhere, @task)
    assert_response :not_found
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
  end

  test "an address from before organizations goes to the organization that holds it" do
    @elsewhere.memberships.create!(user: @riley)
    elsewhere_pi = Agent.create!(owner: @riley.reload, handle: "pi-2", oauth_client_id: "client-d", organization: @elsewhere)
    their_task = Task.open!(recipient: elsewhere_pi, caller: @hermes)
    sign_in_via_ajent(subject: "7", email: "riley@example.com", name: "Riley")

    get "/tasks/#{their_task.id}"
    assert_redirected_to "/elsewhere/tasks/#{their_task.id}"
    get "/agents/riley/pi-2/edit"
    assert_redirected_to "/elsewhere/agents/riley/pi-2/edit"
    get "/tasks?filter=open"
    assert_redirected_to "/concourse/tasks?filter=open"
    get "/"
    assert_redirected_to "/concourse"

    get my_task_path(@elsewhere, their_task)
    assert_response :success
    assert_equal @elsewhere.id, session[:organization_id]
    get "/"
    assert_redirected_to "/elsewhere"
  end

  test "an agent's recipients are in its own organization" do
    with_memory_cache do
      stub_agent_token("token-sam", client_id: "client-c", sub: "9", organization: @elsewhere)
      stub_agent_token("token-ajay", client_id: "client-a", sub: "42")

      body = rpc(owner: "riley", agent: "pi", token: "token-sam", method: "SendMessage",
        params: { message: { role: "ROLE_USER", messageId: "m-1", parts: [ { text: "hi" } ] } })
      assert_equal A2a::Error::CODES[:task_not_found], body.dig("error", "code")

      body = rpc(owner: "riley", agent: "pi", token: "token-sam", method: "GetTask", params: { id: @task.id })
      assert_equal A2a::Error::CODES[:task_not_found], body.dig("error", "code")

      body = rpc(owner: "sam", agent: "hermes", token: "token-ajay", method: "GetExtendedAgentCard")
      assert_equal A2a::Error::CODES[:task_not_found], body.dig("error", "code")

      get "/agents", headers: { "Authorization" => "Bearer token-sam" }
      assert_equal [ "sam/hermes" ], response.parsed_body["agents"].map { |agent| agent["handle"] }
    end
    assert_equal 2, Task.count
  end

  test "the MCP bridge finds and sends only within the organization" do
    with_memory_cache do
      stub_agent_token("token-sam", client_id: "client-c", sub: "9", organization: @elsewhere, resource: :mcp)

      sent = mcp_call("token-sam", "send_message", { "to" => "riley/pi", "text" => "hi" })
      assert_equal true, sent.dig("result", "isError")

      found = mcp_call("token-sam", "find_agents", {})
      assert_equal [ "sam/hermes" ], found.dig("result", "structuredContent", "agents").map { |agent| agent["handle"] }
    end
  end

  test "a public card is at its organization's address, and the older address is the default organization's" do
    get "/a2a/elsewhere/sam/hermes/.well-known/agent-card.json"
    assert_response :success
    assert_equal "#{Concourse.app_url}/a2a/elsewhere/sam/hermes", response.parsed_body.dig("supportedInterfaces", 0, "url")
    get "/a2a/concourse/sam/hermes/.well-known/agent-card.json"
    assert_response :not_found
    get "/a2a/nowhere/sam/hermes/.well-known/agent-card.json"
    assert_response :not_found

    get "/a2a/riley/pi/.well-known/agent-card.json"
    assert_response :success
    get "/a2a/sam/hermes/.well-known/agent-card.json"
    assert_response :not_found
  end

  test "an agent reaches another at either address, but only in its own organization" do
    with_memory_cache do
      stub_agent_token("token-ajay", client_id: "client-a", sub: "42")
      stub_agent_token("token-sam", client_id: "client-c", sub: "9", organization: @elsewhere)

      body = rpc(owner: "riley", agent: "pi", token: "token-ajay", method: "GetTask", params: { id: @task.id }, organization: nil)
      assert_equal @task.id, body.dig("result", "id")
      body = rpc(owner: "riley", agent: "pi", token: "token-ajay", method: "GetTask", params: { id: @task.id })
      assert_equal @task.id, body.dig("result", "id")

      body = rpc(owner: "sam", agent: "hermes", token: "token-sam", method: "GetExtendedAgentCard", organization: @elsewhere)
      assert_equal "elsewhere", body.dig("result", "capabilities", "extensions", 0, "params", "organization")
      body = rpc(owner: "sam", agent: "hermes", token: "token-sam", method: "GetExtendedAgentCard", organization: @home)
      assert_equal A2a::Error::CODES[:task_not_found], body.dig("error", "code")
    end
  end
end
