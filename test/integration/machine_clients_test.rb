require "test_helper"
require_relative "../support/machine_clients"

class MachineClientsTest < ActionDispatch::IntegrationTest
  include MachineClients
  setup { setup_machine_client }
  teardown { restore_machine_settings }

  test "standard subject-free introspection reaches the existing identity without provisioning" do
    stub_machine
    assert_no_difference [ -> { User.count }, -> { Agent.count }, -> { Membership.count }, -> { Agent::ClientBinding.count } ] do
      get api_identity_path, headers: bearer
    end
    assert_response :success
    assert_equal @agent.id, response.parsed_body["agent_id"]
    assert_equal @owner.id, response.parsed_body["owner_id"]
    assert_equal "human-profile", @agent.reload.oauth_client_id
    assert_nil @owner.reload.email
  end

  test "machine clients turned off, or the configured legacy organization even with them on, deny a valid binding" do
    stub_machine
    @organization.update!(machine_clients: false)
    get api_identity_path, headers: bearer
    assert_rejected

    @organization.update!(machine_clients: true)
    @machine_settings.legacy_organization = @organization.slug
    get api_identity_path, headers: bearer
    assert_rejected
  end

  # Admission rereads the setting on every request, cache hits included, so
  # off takes effect at once. It revokes nothing, so on resumes the client.
  test "an owner turning machine clients off refuses a cached client at its next request, and on resumes it" do
    admin = User.create!(ajent_sub: "lab-admin", handle: "lab-admin", email: "admin@machine.test", name: "Admin")
    @organization.memberships.create!(user: admin, role: "owner")
    with_memory_cache do
      stub_machine
      get api_identity_path, headers: bearer
      assert_response :success

      sign_in_via_ajent(subject: "lab-admin", email: "admin@machine.test", name: "Admin")
      patch organization_path(@organization), params: { organization: { machine_clients: "0" } }
      assert_redirected_to edit_organization_path(@organization)
      get api_identity_path, headers: bearer
      assert_rejected
      assert_nil @binding.reload.revoked_at

      patch organization_path(@organization), params: { organization: { machine_clients: "1" } }
      get api_identity_path, headers: bearer
      assert_response :success
      assert_requested :post, AgentTokens::INTROSPECT, times: 1
    end
  end

  test "malformed standard payloads and both old private profile downgrades create nothing" do
    invalid = [
      { "active" => false }, { "active" => "true" }, { "client_id" => nil }, { "client_id" => 42 },
      { "client_id" => "unknown-client" }, { "scope" => "openid concourse" }, { "scope" => [ "concourse" ] },
      { "aud" => "#{Concourse.app_url}/mcp" }, { "aud" => "#{Concourse.app_url}/" },
      { "aud" => [ Concourse.app_url, "https://other.example" ] }, { "aud" => [] },
      { "exp" => nil }, { "exp" => 1.minute.ago.to_i }, { "exp" => 1.hour.from_now.to_i.to_s },
      { "sub" => @owner.ajent_sub }, { "sub" => nil }, { "sub" => "" },
      { "username" => "claimed@example.test" }, { "email" => "claimed@example.test" },
      { "token_use" => "agent", "agent" => { "handle" => @agent.qualified_handle, "org" => @organization.slug } },
      { "token_use" => "user" }, { "agent" => {} }
    ]
    invalid.each do |changes|
      stub_machine(@payload.merge(changes))
      assert_no_difference [ -> { User.count }, -> { Agent.count }, -> { Membership.count }, -> { Agent::ClientBinding.count } ] do
        get api_identity_path, headers: bearer
        assert_rejected
      end
      assert_nil @agent.reload.last_seen_at
    end
  end

  test "old machine profile with an unreserved client cannot enter the human path" do
    stub_machine(@payload.merge("client_id" => "old-client", "sub" => @owner.ajent_sub,
      "token_use" => "agent", "agent" => { "handle" => @agent.qualified_handle }))
    assert_no_difference -> { Agent.count } do
      get api_identity_path, headers: bearer
      assert_rejected
    end
  end

  test "no subject and no reservation never enrolls a client" do
    stub_machine(@payload.merge("client_id" => "new-client"))
    assert_no_difference -> { Agent::ClientBinding.count } do
      get api_identity_path, headers: bearer
      assert_rejected
    end
  end

  test "human registration still works including explicit user typing and shared clients" do
    [ "owner-a", "owner-b" ].each do |subject|
      stub_agent_token(subject, sub: subject, client_id: "shared-human", organization: @organization)
      get api_identity_path, headers: bearer(subject)
      assert_response :success
      assert_not_equal @agent.id, response.parsed_body["agent_id"]
    end
    human = @payload.merge("client_id" => "human-profile", "sub" => @owner.ajent_sub, "token_use" => "user")
    stub_machine(human)
    get api_identity_path, headers: bearer
    assert_response :success
    assert_equal @agent.id, response.parsed_body["agent_id"]
  end

  test "local disable membership removal and revocation reject cached credentials" do
    with_memory_cache do
      stub_machine
      get api_identity_path, headers: bearer
      assert_response :success
      @organization.update!(machine_clients: false)
      get api_identity_path, headers: bearer
      assert_rejected
      @organization.update!(machine_clients: true)
      @owner.memberships.delete_all
      get api_identity_path, headers: bearer
      assert_rejected
      @owner.memberships.create!(organization: @organization)
      @binding.revoke!
      get api_identity_path, headers: bearer
      assert_rejected
      assert_requested :post, AgentTokens::INTROSPECT, times: 1
    end
  end

  test "physical deletion rejects a cached unrevoked credential" do
    with_memory_cache do
      stub_machine
      get api_identity_path, headers: bearer
      assert_response :success
      assert_nil @binding.reload.revoked_at
      @owner.destroy!
      get api_identity_path, headers: bearer
      assert_rejected
      assert_nil @binding.reload.agent_id
      assert_requested :post, AgentTokens::INTROSPECT, times: 1
    end
  end

  test "machine cache tolerates outage for less than sixty seconds then returns 503" do
    with_memory_cache do |cache|
      stub_machine
      get api_identity_path, headers: bearer
      assert_response :success
      assert cache.exist?("ajent/introspection/#{Digest::SHA256.hexdigest('machine-token')}")
      stub_request(:post, AgentTokens::INTROSPECT).to_timeout
      travel 59.seconds do
        get api_identity_path, headers: bearer
        assert_response :success
      end
      travel 61.seconds do
        get api_identity_path, headers: bearer
        assert_response :service_unavailable
        assert_equal "30", response.headers["Retry-After"]
        assert_not_includes response.headers["WWW-Authenticate"].to_s, "invalid_token"
      end
    end
  end

  test "token expiry bounds the cache and issuer rejection after cache expiry is 401" do
    with_memory_cache do
      stub_machine(@payload.merge("exp" => 10.seconds.from_now.to_i))
      get api_identity_path, headers: bearer
      assert_response :success
      stub_machine({ "active" => false })
      travel 11.seconds do
        get api_identity_path, headers: bearer
        assert_rejected
      end
      assert_requested :post, AgentTokens::INTROSPECT, times: 2
    end
  end

  test "MCP requires its exact audience even after a cached API request" do
    with_memory_cache do
      stub_machine
      get api_identity_path, headers: bearer
      assert_response :success
      mcp_call("machine-token", "list_projects")
      assert_rejected
      stub_machine(@payload.merge("aud" => [ "#{Concourse.app_url}/mcp" ]), token: "machine-mcp")
      result = mcp_call("machine-mcp", "list_projects")
      assert_response :success
      assert result.dig("result", "structuredContent").key?("projects")
      get api_identity_path, headers: bearer("machine-mcp")
      assert_rejected
    end
  end

  test "A2A sends bind caller from credential and enforce task visibility and worker writes" do
    other = @owner.agents.create!(handle: "other", organization: @organization)
    stub_machine
    sent = rpc(owner: @owner.handle, agent: other.handle, organization: @organization,
      method: "SendMessage", token: "machine-token", params: {
        message: { messageId: "machine-send", role: "ROLE_USER", parts: [ { text: "work" } ],
          metadata: { "concourse.caller" => "spoof/identity" } },
        configuration: { returnImmediately: true }
      })
    assert_response :success
    task = Task.find(sent.fetch("result").fetch("task").fetch("id"))
    assert_equal @agent, task.caller_agent
    assert_equal other, task.recipient_agent
    get "/api/tasks/#{task.id}", headers: bearer
    assert_response :success
    patch worker_task_path(task), params: { state: "TASK_STATE_WORKING" }.to_json,
      headers: bearer.merge("CONTENT_TYPE" => "application/json")
    assert_response :not_found
    inbound = Task.open!(caller: other, recipient: @agent)
    patch worker_task_path(inbound), params: { state: "TASK_STATE_WORKING" }.to_json,
      headers: bearer.merge("CONTENT_TYPE" => "application/json")
    assert_response :success
    unrelated = Task.open!(caller: other, recipient: other)
    get "/api/tasks/#{unrelated.id}", headers: bearer
    assert_response :not_found
    get worker_inbox_path(other), headers: bearer
    assert_response :not_found
  end

  test "a valid machine cannot address another organization" do
    other_org = Organization.create!(name: "Other Lab")
    @owner.memberships.create!(organization: other_org)
    @owner.reload
    other = @owner.agents.create!(handle: "elsewhere", organization: other_org)
    stub_machine
    task = Task.open!(caller: other, recipient: other)
    result = rpc(owner: @owner.handle, agent: other.handle, organization: other_org,
      method: "GetTask", token: "machine-token", params: { id: task.id })
    assert_response :success
    assert_equal A2a::Error::CODES[:task_not_found], result.dig("error", "code")
    get "/api/tasks/#{task.id}", headers: bearer
    assert_response :not_found
  end

  test "unregistered machine bearer is rejected on every protected entry surface" do
    stub_machine(@payload.merge("client_id" => "unbound"))
    [ api_identity_path, "/agents", "/api/tasks", "/api/doorbell", worker_inbox_path(@agent) ].each do |path|
      get path, headers: bearer
      assert_rejected
    end
    rpc(owner: @owner.handle, agent: @agent.handle, organization: @organization,
      method: "GetTask", token: "machine-token", params: { id: "missing" })
    assert_rejected
    stub_machine(@payload.merge("client_id" => "unbound", "aud" => "#{Concourse.app_url}/mcp"))
    mcp_call("machine-token", "list_projects")
    assert_rejected
  end

  test "human cache ceiling remains ten minutes rather than the machine ceiling" do
    with_memory_cache do
      human = @payload.merge("client_id" => "human-profile", "sub" => @owner.ajent_sub)
      stub_machine(human)
      get api_identity_path, headers: bearer
      assert_response :success
      stub_request(:post, AgentTokens::INTROSPECT).to_timeout
      travel 9.minutes do
        get api_identity_path, headers: bearer
        assert_response :success
      end
      travel 11.minutes do
        get api_identity_path, headers: bearer
        assert_response :service_unavailable
      end
    end
  end

  test "machine authenticates to doorbell before existing capacity policy" do
    stub_machine
    A2a::Waiters.limit = 1
    lease = A2a::Waiters.acquire(@organization.id)
    assert lease
    get "/api/doorbell", headers: bearer
    assert_response :too_many_requests
    assert_equal "doorbell_capacity", response.parsed_body["error"]
  ensure
    A2a::Waiters.release(@organization.id) if lease
    A2a::Waiters.limit = nil
    A2a::Waiters.reset!
  end

  test "local reservation wins over a cached human-shaped assertion" do
    with_memory_cache do |cache|
      cached = @payload.merge("sub" => @owner.ajent_sub, "username" => "forged@example.test")
      cache.write("ajent/introspection/#{Digest::SHA256.hexdigest('machine-token')}", cached, expires_in: 10.minutes)
      assert_no_difference -> { Agent.count } do
        get api_identity_path, headers: bearer
        assert_rejected
      end
      assert_nil @owner.reload.email
      assert_not_requested :post, AgentTokens::INTROSPECT
    end
  end

  test "unbound rejected payload is not cached and cannot poison later requests" do
    with_memory_cache do |cache|
      stub_machine(@payload.merge("client_id" => "unbound"))
      get api_identity_path, headers: bearer
      assert_rejected
      assert_not cache.exist?("ajent/introspection/#{Digest::SHA256.hexdigest('machine-token')}")
      stub_machine
      get api_identity_path, headers: bearer
      assert_response :success
    end
  end


  private

  def bearer(token = "machine-token")
    { "Authorization" => "Bearer #{token}" }
  end

  def assert_rejected
    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], 'error="invalid_token"'
  end
end
