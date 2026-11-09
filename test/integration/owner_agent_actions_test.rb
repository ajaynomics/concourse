require "test_helper"

# An owner's own signed-in agent approves, declines and retires agents over
# REST and MCP, with the web's rules. An app's unattended credential never
# does, even when its owner owns the organization.
class OwnerAgentActionsTest < ActionDispatch::IntegrationTest
  setup do
    @settings = Rails.application.config.x.concourse
    @old_release = @settings.release_line
    @settings.release_line = 3
    @firm = Organization.create!(name: "Firm", slug: "firm", admission: "approval", machine_clients: true)
    @boss = User.create!(ajent_sub: "boss-sub", handle: "boss", email: "boss@firm.test", email_verified: true)
    @firm.memberships.create!(user: @boss, role: "owner")
    @pi = @boss.agents.create!(organization: @firm, handle: "pi", oauth_client_id: "boss-pi")
    @mal = User.create!(ajent_sub: "mal-sub", handle: "mal", email: "mal@firm.test", email_verified: true)
    @firm.memberships.create!(user: @mal)
    @waiting = @mal.agents.create!(organization: @firm, oauth_client_id: "mal-new", admitted_at: nil)
    @network = @firm.agents.find_by!(owner: User.system)
    stub_agent_token("boss", client_id: "boss-pi", sub: "boss-sub", organization: @firm)
    stub_agent_token("boss-mcp", client_id: "boss-pi", sub: "boss-sub", organization: @firm, resource: :mcp)
  end

  teardown { @settings.release_line = @old_release }

  test "the owner's agent lists only its organization's waiting agents" do
    declined = @mal.agents.create!(organization: @firm, oauth_client_id: "mal-old", admitted_at: nil, declined_at: Time.current)
    elsewhere = Organization.create!(name: "Elsewhere", slug: "elsewhere", admission: "approval")
    elsewhere.memberships.create!(user: @mal)
    foreign = @mal.agents.create!(organization: elsewhere, oauth_client_id: "mal-far", admitted_at: nil)

    get api_pending_agents_path, headers: bearer("boss")

    assert_response :success
    agents = response.parsed_body["agents"]
    assert_equal [ @waiting.id ], agents.pluck("id")
    assert_equal({ "id" => @waiting.id, "address" => nil, "name" => nil, "owner" => "mal", "client_id" => "mal-new",
      "requested_at" => @waiting.created_at.iso8601 }, agents.sole)
    assert_not_includes agents.pluck("id"), declined.id
    assert_not_includes agents.pluck("id"), foreign.id
  end

  test "approve admits once, a repeat changes nothing, and a declined agent may be approved again as on the web" do
    capture_events("concourse.agent.approved") do |events|
      post api_agent_approval_path(@waiting), headers: bearer("boss")
      assert_response :success
      assert_equal({ "id" => @waiting.id, "address" => nil, "status" => "admitted" }, response.parsed_body)
      assert @waiting.reload.admitted?
      admitted_at = @waiting.admitted_at

      post api_agent_approval_path(@waiting), headers: bearer("boss")
      assert_response :success
      assert_equal "admitted", response.parsed_body["status"]
      assert_equal admitted_at, @waiting.reload.admitted_at
      assert_equal 1, events.size
    end

    @waiting.decline
    post api_agent_approval_path(@waiting), headers: bearer("boss")
    assert_response :success
    assert @waiting.reload.admitted?
  end

  test "decline refuses a waiting agent once, and an admitted agent is retired instead" do
    capture_events("concourse.agent.declined") do |events|
      delete api_pending_agent_path(@waiting), headers: bearer("boss")
      assert_response :success
      assert_equal "declined", response.parsed_body["status"]
      declined_at = @waiting.reload.declined_at
      assert declined_at

      delete api_pending_agent_path(@waiting), headers: bearer("boss")
      assert_response :success
      assert_equal declined_at, @waiting.reload.declined_at
      assert_equal 1, events.size
    end

    admitted = @mal.agents.create!(organization: @firm, handle: "worker", oauth_client_id: "mal-worker")
    delete api_pending_agent_path(admitted), headers: bearer("boss")
    assert_response :unprocessable_content
    assert_equal "not_pending", response.parsed_body["error"]
    assert admitted.reload.admitted?
  end

  test "retire withdraws access and revokes an app credential once, keeps history, and never retires the caller" do
    app = @mal.agents.create!(organization: @firm, handle: "app")
    binding = Agent::ClientBinding.bind!(agent: app, client_id: "mal-app", verified_owner_sub: @mal.ajent_sub)
    task = Task.open!(caller: @pi, recipient: app)

    capture_events("concourse.agent.retired") do |events|
      post api_agent_retirement_path(app), headers: bearer("boss")
      assert_response :success
      assert_equal({ "id" => app.id, "address" => "mal/app", "status" => "declined" }, response.parsed_body)
      assert_not app.reload.admitted?
      assert binding.reload.revoked_at
      first = [ app.declined_at, binding.revoked_at ]

      post api_agent_retirement_path(app), headers: bearer("boss")
      assert_response :success
      assert_equal first, [ app.reload.declined_at, binding.reload.revoked_at ]
      assert_equal 1, events.size
    end
    assert_equal app, task.reload.recipient_agent

    post api_agent_retirement_path(@pi), headers: bearer("boss")
    assert_response :unprocessable_content
    assert_equal "self_retirement", response.parsed_body["error"]
    assert @pi.reload.admitted?
  end

  test "the network agent and another organization's agents are not found" do
    elsewhere = Organization.create!(name: "Elsewhere", slug: "elsewhere", admission: "approval")
    elsewhere.memberships.create!(user: @boss, role: "owner")
    foreign = @boss.agents.create!(organization: elsewhere, oauth_client_id: "boss-far", admitted_at: nil)

    [ @network, foreign ].each do |target|
      each_action(target) do |verb, path|
        send(verb, path, headers: bearer("boss"))
        assert_response :not_found
        assert_equal({ "error" => "not_found" }, response.parsed_body)
      end
    end
    post "/api/agents/#{@waiting.id}abc/approval", headers: bearer("boss")
    assert_response :not_found
    assert @network.reload.admitted?
    assert foreign.reload.pending?
  end

  test "a member who is not an owner, or no longer one, is refused before any lookup" do
    @mal.agents.create!(organization: @firm, handle: "pi", oauth_client_id: "mal-pi")
    stub_agent_token("mal", client_id: "mal-pi", sub: "mal-sub", organization: @firm)
    assert_refused("mal", "owner_required")

    @firm.memberships.find_by!(user: @mal).update!(role: "owner")
    @firm.memberships.find_by!(user: @boss).update!(role: "member")
    assert_refused("boss", "owner_required")
  end

  test "an app's unattended credential is refused even when its owner owns the organization" do
    operator = @boss.agents.create!(organization: @firm, handle: "operator-app")
    Agent::ClientBinding.bind!(agent: operator, client_id: "boss-operator", verified_owner_sub: @boss.ajent_sub)
    connected = @boss.agents.create!(organization: @firm, handle: "connected-app")
    Agent::ClientBinding.bind_connected!(agent: connected, client_id: "boss-connected", verified_owner_sub: @boss.ajent_sub)

    { "operator-token" => "boss-operator", "connected-token" => "boss-connected" }.each do |token, client_id|
      stub_machine_token(token, client_id)
      get api_identity_path, headers: bearer(token)
      assert_response :success
      assert_equal @boss.id, response.parsed_body["owner_id"]
      assert_refused(token, "machine_client")
    end
  end

  test "a reserved client presenting the owner's subject stays on the machine path" do
    app = @boss.agents.create!(organization: @firm, handle: "app")
    Agent::ClientBinding.bind!(agent: app, client_id: "boss-app", verified_owner_sub: @boss.ajent_sub)
    stub_agent_token("borrowed", client_id: "boss-app", sub: "boss-sub", organization: @firm)

    post api_agent_approval_path(@waiting), headers: bearer("borrowed")
    assert_response :unauthorized
    assert @waiting.reload.pending?
  end

  test "MCP tools act through the same authority and refuse with plain errors" do
    listed = mcp_call("boss-mcp", "list_pending_agents")
    assert_equal [ @waiting.id ], listed.dig("result", "structuredContent", "agents").pluck("id")

    approved = mcp_call("boss-mcp", "approve_agent", { "agent_id" => @waiting.id })
    assert_equal({ "id" => @waiting.id, "address" => nil, "status" => "admitted" }, approved.dig("result", "structuredContent"))
    retired = mcp_call("boss-mcp", "retire_agent", { "agent_id" => @waiting.id })
    assert_equal "declined", retired.dig("result", "structuredContent", "status")
    other = @mal.agents.create!(organization: @firm, oauth_client_id: "mal-other", admitted_at: nil)
    declined = mcp_call("boss-mcp", "decline_agent", { "agent_id" => other.id })
    assert_equal "declined", declined.dig("result", "structuredContent", "status")

    { "retire_agent" => [ @pi.id, "self_retirement" ], "decline_agent" => [ @network.id, "not_found" ] }.each do |tool, (id, code)|
      refused = mcp_call("boss-mcp", tool, { "agent_id" => id })
      assert_equal true, refused.dig("result", "isError")
      assert_equal code, refused.dig("result", "structuredContent", "code")
    end

    app = @boss.agents.create!(organization: @firm, handle: "app")
    Agent::ClientBinding.bind!(agent: app, client_id: "boss-app", verified_owner_sub: @boss.ajent_sub)
    stub_machine_token("app-mcp", "boss-app", resource: "#{Concourse.app_url}/mcp")
    %w[list_pending_agents approve_agent decline_agent retire_agent].each do |tool|
      arguments = tool == "list_pending_agents" ? {} : { "agent_id" => other.id }
      refused = mcp_call("app-mcp", tool, arguments)
      assert_equal true, refused.dig("result", "isError"), tool
      assert_equal "machine_client", refused.dig("result", "structuredContent", "code")
    end
    assert other.reload.declined?
  end

  # Identifiers only: no names, handles, client IDs or task content.
  test "events name the organization, the agent and the acting agent, nothing more" do
    capture_events do |events|
      post api_agent_approval_path(@waiting), headers: bearer("boss")
      post api_agent_retirement_path(@waiting), headers: bearer("boss")
      other = @mal.agents.create!(organization: @firm, oauth_client_id: "mal-other", admitted_at: nil)
      delete api_pending_agent_path(other), headers: bearer("boss")

      owner_events = events.select { |event| event[:name].start_with?("concourse.agent.") }
      assert_equal %w[concourse.agent.approved concourse.agent.retired concourse.agent.declined], owner_events.pluck(:name)
      owner_events.each do |event|
        assert_equal %i[acting_agent_id agent_id organization via], event[:payload].keys.sort
        assert_equal({ organization: "firm", via: "agent", acting_agent_id: @pi.id }, event[:payload].except(:agent_id))
      end
    end
  end

  private

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def each_action(target)
    yield :post, api_agent_approval_path(target)
    yield :delete, api_pending_agent_path(target)
    yield :post, api_agent_retirement_path(target)
  end

  def assert_refused(token, code)
    before = @firm.agents.order(:id).map { |agent| agent.slice(:admitted_at, :declined_at) }
    capture_events do |events|
      get api_pending_agents_path, headers: bearer(token)
      assert_response :forbidden
      assert_equal code, response.parsed_body["error"]
      each_action(@waiting) do |verb, path|
        send(verb, path, headers: bearer(token))
        assert_response :forbidden
        assert_equal code, response.parsed_body["error"]
      end
      # Refused before lookup: a missing agent answers the same.
      post api_agent_approval_path(0), headers: bearer(token)
      assert_response :forbidden
      assert_empty events.select { |event| event[:name].start_with?("concourse.agent.") }
    end
    assert_equal before, @firm.agents.order(:id).map { |agent| agent.slice(:admitted_at, :declined_at) }
  end

  def stub_machine_token(token, client_id, resource: Concourse.app_url)
    payload = { "active" => true, "scope" => "concourse", "client_id" => client_id, "aud" => resource,
      "exp" => 1.hour.from_now.to_i, "iat" => Time.current.to_i, "token_type" => "Bearer" }
    stub_request(:post, AgentTokens::INTROSPECT).with(body: hash_including("token" => token))
      .to_return(status: 200, body: payload.to_json, headers: { "Content-Type" => "application/json" })
  end
end
