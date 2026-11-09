require "test_helper"

class NativeEndpointRegistrationTest < ActionDispatch::IntegrationTest
  setup do
    @organization = Organization.default
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ @organization ])
    other = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ @organization ])
    @agent = Agent.create!(owner: @owner, handle: "native", oauth_client_id: "foundation-client")
    @caller = Agent.create!(owner: other, handle: "caller", oauth_client_id: "foundation-caller")
    @path = "/#{@organization.slug}/agents/ajay/native/native_endpoint"
    @previous = Rails.application.config.x.relay
    @registration = { endpoint_url: "https://native.example/a2a", card_url: "https://native.example/.well-known/agent-card.json", resource: "https://native.example/a2a" }
    Rails.application.config.x.relay = { allowed_endpoints: [ @registration.merge(organization_id: @organization.id, recipient_id: @agent.id) ] }
  end

  teardown { Rails.application.config.x.relay = @previous }

  test "owner-only registration remains off and cannot be edited through agent bearer card updates" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com")
    post @path, params: { native_endpoint: @registration }, as: :json
    assert_response :success
    assert_equal false, response.parsed_body["activationAvailable"]
    assert_equal false, response.parsed_body["native_enabled"]
    assert_equal 1, @agent.reload.native_generation
    get @path
    assert_response :success
    assert_equal @registration[:endpoint_url], response.parsed_body["native_endpoint_url"]
    assert_not_requested :any, /native\.example/

    with_memory_cache do
      stub_agent_token("foundation-token", client_id: "foundation-client", sub: "42")
      patch "/api/card", params: { handle: "native", native_endpoint_url: "https://attacker.example/a2a", native_enabled: true }.to_json,
        headers: { "Authorization" => "Bearer foundation-token", "CONTENT_TYPE" => "application/json" }
      assert_response :success
      assert_equal @registration[:endpoint_url], @agent.reload.native_endpoint_url
      assert_not @agent.native_enabled?
    end
    delete @path
    assert_response :no_content
    assert_nil @agent.reload.native_endpoint_url
  end

  test "another member cannot read change or delete the registration and unapproved routes fail" do
    sign_in_via_ajent(subject: "7", email: "riley@example.com")
    get @path
    assert_response :not_found
    patch @path, params: { native_endpoint: @registration }, as: :json
    assert_response :not_found
    delete @path
    assert_response :not_found
    sign_in_via_ajent(subject: "42", email: "ajay@example.com")
    patch @path, params: { native_endpoint: @registration.merge(resource: "https://foreign.example/a2a") }, as: :json
    assert_response :unprocessable_content
    assert_nil @agent.reload.native_endpoint_url
  end

  test "pending receipts prevent registration deletion even before any task exists" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com")
    post @path, params: { native_endpoint: @registration }, as: :json
    assert_response :success
    RelayDelivery.reserve!(caller: @caller, recipient: @agent, message: { "messageId" => "pending", "parts" => [ { "text" => "input" } ] })
    delete @path
    assert_response :unprocessable_content
    assert_equal @registration[:endpoint_url], @agent.reload.native_endpoint_url
  end

  test "native and held submitted records never appear in worker inbox or next_task and worker writes reject" do
    tasks = %w[native held].map do |route|
      Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @agent, execution_route: route)
    end
    with_memory_cache do
      stub_agent_token("foundation-token", client_id: "foundation-client", sub: "42")
      headers = { "Authorization" => "Bearer foundation-token" }
      get worker_inbox_path(@agent), headers: headers
      assert_response :success
      assert_empty response.parsed_body["tasks"]
      A2a::Exchange.with_limits(inbox: 0) do
        get "/api/next_task", headers: headers
        assert_response :success
        assert_nil response.parsed_body["task"]
      end
      tasks.each do |task|
        post worker_task_messages_path(task), params: { parts: [ { text: "reply" } ] }.to_json,
          headers: headers.merge("CONTENT_TYPE" => "application/json")
        assert_response :not_found
        post worker_task_artifacts_path(task), params: { parts: [ { text: "artifact" } ] }.to_json,
          headers: headers.merge("CONTENT_TYPE" => "application/json")
        assert_response :not_found
        patch worker_task_path(task), params: { state: "TASK_STATE_WORKING" }.to_json,
          headers: headers.merge("CONTENT_TYPE" => "application/json")
        assert_response :unprocessable_entity
        assert_equal "TASK_STATE_SUBMITTED", task.reload.state
        assert_empty task.messages
        assert_empty task.artifacts
      end
    end
  end

  test "recipient owner cannot reply to native or held task on the web" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com")
    %w[native held].each do |route|
      task = Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @agent, execution_route: route)
      post my_task_response_path(@organization, task), params: { side: "recipient", text: "reply", state: "TASK_STATE_COMPLETED" }
      assert_redirected_to my_task_path(@organization, task)
      assert flash[:alert]
      assert_empty task.messages
      assert_equal "TASK_STATE_SUBMITTED", task.reload.state
    end
  end
end
