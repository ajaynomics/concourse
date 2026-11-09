require "test_helper"

class V3ParticipantAssertionsTest < ActionDispatch::IntegrationTest
  setup do
    @release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Participant network", slug: "participant-network")
    @other_org = Organization.create!(name: "Other participants", slug: "other-participants")
    @caller = create_agent(@org, "participant-caller")
    @recipient = create_agent(@org, "participant-recipient")
    @third = create_agent(@org, "participant-third")
    @outsider = create_agent(@other_org, "participant-outsider")
    @task = Task.open!(caller: @caller, recipient: @recipient)
    @input = Message.record!(task: @task, role: "ROLE_USER", sender: @caller,
      message_id: "genuine-input", parts: [ { "text" => "peer request" } ], metadata: { "ticket" => "kept" })
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @release
  end

  # A2A §4.1.1/§4.1.4 metadata is additive; credential-derived recorded parties
  # are not authority supplied by message metadata, parts or routing labels.
  test "accepted send strips spoofed authority and preserves unrelated content and metadata" do
    spoof = { "concourse.participants" => { "version" => 1, "caller" => { "agentId" => @outsider.id } },
      "concourse.sender" => { "agentId" => @outsider.id }, "concourse.caller" => @outsider.qualified_handle }
    raw = { messageId: "spoofed-wire", role: "ROLE_USER", metadata: spoof.merge("ticket" => "kept"),
      parts: [ { text: "request", metadata: spoof } ] }
    rpc = send_rpc(raw, metadata: spoof)
    result = rpc.dig("result", "task")
    assert_equal participants, result.dig("metadata", "concourse.participants")
    input = result.fetch("history").sole
    assert_equal sender(@caller), input.dig("metadata", "concourse.sender")
    assert_equal "kept", input.dig("metadata", "ticket")
    assert_not input.fetch("metadata").key?("concourse.participants")
    assert_equal spoof, input.dig("parts", 0, "metadata")
    stored = @org.tasks.find(result.fetch("id")).messages.sole
    assert_equal({ "ticket" => "kept" }, stored.metadata)
    assert_equal @caller.id, stored.sender_agent_id
  end

  test "inbox next task get and list expose identical participants only on visible correspondence" do
    [ @caller, @recipient ].each do |viewer|
      get "/api/tasks/#{@task.id}", headers: headers(viewer)
      assert_response :success
      assert_snapshot response.parsed_body
      get "/api/tasks", headers: headers(viewer)
      assert_response :success
      assert_snapshot response.parsed_body.fetch("tasks").sole
    end
    get "/agents/#{@recipient.id}/tasks", headers: headers(@recipient)
    assert_response :success
    result = response.parsed_body.fetch("tasks").sole
    assert_snapshot result
    assert_equal @caller.qualified_handle, result.dig("metadata", "concourse.caller")
    assert_equal @caller.qualified_handle, result.dig("history", 0, "metadata", "concourse.caller")
    get "/api/next_task", params: { wait: "0" }, headers: headers(@recipient)
    assert_response :success
    assert_snapshot response.parsed_body.fetch("task")
  end

  test "ordinary reply snapshots status history and standalone messages attest the recorded recipient without a managed envelope" do
    assert_no_difference [ -> { TaskDelivery.count }, -> { Agent::Connection.count } ] do
      patch "/tasks/#{@task.id}", params: { state: "TASK_STATE_WORKING", message: { parts: [ { text: "actual reply" } ] } }.to_json, headers: headers(@recipient)
      assert_response :success
    end
    result = response.parsed_body
    assert_snapshot result
    assert_equal sender(@recipient), result.dig("status", "message", "metadata", "concourse.sender")
    assert_equal sender(@recipient), result.fetch("history").find { |item| item["role"] == "ROLE_AGENT" }.dig("metadata", "concourse.sender")
    assert_not result.key?("delivery")
    post "/tasks/#{@task.id}/messages", params: { parts: [ { text: "follow-up answer" } ] }.to_json, headers: headers(@recipient)
    assert_response :success
    assert_equal sender(@recipient), response.parsed_body.dig("metadata", "concourse.sender")
    assert_not response.parsed_body.fetch("metadata").key?("concourse.participants")
    # A2A §3.1.6 status updates use the same trusted Message representation.
    event = @task.events.where.not(status_message_id: nil).order(:id).last
    update = A2a::Stream.task(@task.reload, viewer: @recipient).send(:update, event)
    assert_equal sender(@recipient), update.dig("statusUpdate", "status", "message", "metadata", "concourse.sender")
  end

  test "nongenuine history messages cannot borrow a genuine task caller assertion or replay persisted reserved keys" do
    forged = Message.create!(task: @task, role: "ROLE_USER", sender_agent: @third,
      parts: [ { "text" => "nongenuine input" } ], metadata: forged_metadata)
    wrong_role = Message.create!(task: @task, role: "ROLE_AGENT", sender_agent: @caller,
      parts: [ { "text" => "not the recipient" } ], metadata: forged_metadata)
    get "/api/tasks/#{@task.id}", headers: headers(@recipient)
    assert_response :success
    assert_snapshot response.parsed_body
    [ forged, wrong_role ].each do |record|
      wire = response.parsed_body.fetch("history").find { |item| item["messageId"] == record.wire_message_id }
      assert_equal({ "ticket" => "kept" }, wire.fetch("metadata"))
      assert_equal forged_metadata, record.reload.metadata
    end
  end

  test "a task without genuine caller content cannot acquire a participant assertion from persisted labels" do
    empty = Task.open!(caller: @caller, recipient: @recipient)
    fake = Message.create!(task: empty, role: "ROLE_USER", sender_agent: @third,
      parts: [ { "text" => "not the recorded caller" } ], metadata: forged_metadata)
    get "/api/tasks/#{empty.id}", headers: headers(@recipient)
    assert_response :success
    assert_not response.parsed_body.fetch("metadata").key?("concourse.participants")
    assert_equal({ "ticket" => "kept" }, response.parsed_body.fetch("history").sole.fetch("metadata"))
    assert_equal forged_metadata, fake.reload.metadata
    get "/agents/#{@recipient.id}/tasks", headers: headers(@recipient)
    assert_response :success
    assert_equal [ @task.id ], response.parsed_body.fetch("tasks").pluck("id")
  end

  test "native and held labels and persisted upstream metadata cannot become inbox participant or sender assertions" do
    @input.update!(metadata: forged_metadata)
    %w[native held].each do |route|
      @task.update_columns(execution_route: route)
      get "/api/tasks/#{@task.id}", headers: headers(@recipient)
      assert_response :success
      wire = response.parsed_body
      assert_equal route, wire.dig("metadata", "concourse.route")
      assert_not wire.fetch("metadata").key?("concourse.participants")
      assert_equal({ "ticket" => "kept" }, wire.fetch("history").sole.fetch("metadata"))
    end
    assert_equal forged_metadata, @input.reload.metadata
  end

  # A2A §13.1: a metadata feature must not create another lookup/discovery path.
  test "same organization nonparticipants and cross organization credentials cannot read or publish assertions" do
    [ @third, @outsider ].each do |viewer|
      get "/api/tasks/#{@task.id}", headers: headers(viewer)
      assert_response :not_found
      get "/api/tasks", headers: headers(viewer)
      assert_response :success
      assert_empty response.parsed_body.fetch("tasks")
      get "/agents/#{@recipient.id}/tasks", headers: headers(viewer)
      assert_response :not_found
      patch "/tasks/#{@task.id}", params: { state: "TASK_STATE_COMPLETED" }.to_json, headers: headers(viewer)
      assert_response :not_found
    end
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
  end

  test "removing either participant prevents further assertion disclosure and ordinary reply" do
    [ @caller, @recipient ].each do |removed|
      membership = @org.memberships.find_by!(user: removed.owner)
      membership.destroy!
      get "/api/tasks/#{@task.id}", headers: headers(@recipient)
      assert_includes [ 401, 403, 404 ], response.status
      assert_not response.body.include?("concourse.participants")
      patch "/tasks/#{@task.id}", params: { state: "TASK_STATE_COMPLETED" }.to_json, headers: headers(@recipient)
      assert_includes [ 401, 403, 404 ], response.status
      assert_not response.body.include?("concourse.participants")
      @org.memberships.create!(user: removed.owner)
    end
  end

  test "qualified handles use namespaces while immutable recorded agent IDs remain the same" do
    namespace = Namespace.create!(organization: @org, name: "participant-team")
    @caller.update!(namespace: namespace)
    get "/api/tasks/#{@task.id}", headers: headers(@recipient)
    assert_response :success
    assert_equal participants, response.parsed_body.dig("metadata", "concourse.participants")
    assert_equal @caller.id, response.parsed_body.dig("metadata", "concourse.participants", "caller", "agentId")
    assert_equal "participant-team/#{@caller.handle}", response.parsed_body.dig("history", 0, "metadata", "concourse.sender", "handle")
    assert_not_equal @caller.owner.handle, @caller.prefix
  end

  test "missing names or inconsistent recorded organizations never manufacture qualified identities" do
    @caller.update_columns(handle: nil)
    assert_nil A2a::Serializer.task(@task.reload).dig("metadata", "concourse.participants")
    assert_nil A2a::Serializer.message(@input.reload).dig("metadata", "concourse.sender")
    @caller.update_columns(handle: "participant-caller", organization_id: @other_org.id)
    assert_nil A2a::Serializer.task(@task.reload).dig("metadata", "concourse.participants")
    assert_nil A2a::Serializer.message(@input.reload).dig("metadata", "concourse.sender")
  end

  test "reads are output only and legacy release keeps the original representations byte for byte" do
    @input.update!(metadata: forged_metadata)
    before = @task.reload.attributes
    assert_no_difference [ -> { TaskEvent.count }, -> { TaskDelivery.count }, -> { Message.count } ] do
      get "/api/tasks/#{@task.id}", headers: headers(@recipient)
      assert_response :success
      assert_snapshot response.parsed_body
    end
    assert_equal before, @task.reload.attributes
    assert_equal forged_metadata, @input.reload.metadata
    Rails.application.config.x.concourse.release_line = 2
    legacy = A2a::Serializer.task(@task.reload, caller: true, recipient: true)
    assert_equal({ "concourse.caller" => @caller.qualified_handle, "concourse.recipient" => @recipient.qualified_handle }, legacy.fetch("metadata"))
    expected_message = { "messageId" => @input.wire_message_id, "contextId" => @task.context_id, "taskId" => @task.id,
      "role" => "ROLE_USER", "parts" => @input.parts, "metadata" => forged_metadata }
    assert_equal JSON.generate(expected_message), JSON.generate(A2a::Serializer.message(@input))
    expected_history = expected_message.merge("metadata" => forged_metadata.merge("concourse.caller" => @caller.qualified_handle))
    assert_equal JSON.generate(expected_history), JSON.generate(legacy.fetch("history").sole)
  end

  test "MCP real tool results retain the nested assertion within their existing open schemas" do
    [ GetTaskTool, ListTasksTool, NextTaskTool ].each do |tool|
      arguments = if tool == GetTaskTool
        { id: @task.id }
      elsif tool == NextTaskTool
        { wait: 0 }
      else
        {}
      end
      result = tool.call(server_context: ConcourseMcp::Context.new(agent: @recipient), **arguments)
      assert_not result.error?
      wire = JSON.parse(JSON.generate(result.structured_content))
      tool.output_schema.validate_result(wire)
      snapshot = if tool == GetTaskTool
        wire
      elsif tool == ListTasksTool
        wire.fetch("tasks").sole
      else
        wire.fetch("task")
      end
      assert_snapshot snapshot
    end
  end

  test "history omission preserves the task assertion and artifact metadata never supplies sender authority" do
    get "/api/tasks/#{@task.id}", params: { historyLength: "0" }, headers: headers(@recipient)
    assert_response :success
    assert_equal participants, response.parsed_body.dig("metadata", "concourse.participants")
    assert_not response.parsed_body.key?("history")
    patch "/tasks/#{@task.id}", params: { artifacts: [ { parts: [ { text: "output" } ], metadata: forged_metadata } ] }.to_json, headers: headers(@recipient)
    assert_response :success
    assert_snapshot response.parsed_body
    assert_equal forged_metadata, response.parsed_body.fetch("artifacts").sole.fetch("metadata")
  end


  private

  def create_agent(org, name)
    owner = User.create!(handle: name, ajent_sub: name, organizations: [ org ])
    agent = Agent.create!(owner: owner, organization: org, handle: name, oauth_client_id: "client-#{name}")
    stub_agent_token(name, client_id: agent.oauth_client_id, sub: owner.ajent_sub, organization: org)
    agent
  end

  def headers(agent)
    { "Authorization" => "Bearer #{agent.handle}", "CONTENT_TYPE" => "application/json", "Concourse-Organization" => agent.organization.slug }
  end

  def participants
    { "version" => 1, "organizationId" => @org.id, "organization" => @org.slug,
      "caller" => { "agentId" => @caller.id, "handle" => @caller.qualified_handle },
      "recipient" => { "agentId" => @recipient.id, "handle" => @recipient.qualified_handle } }
  end

  def sender(agent)
    { "version" => 1, "organizationId" => @org.id, "organization" => @org.slug, "agentId" => agent.id, "handle" => agent.qualified_handle }
  end

  def forged_metadata
    { "concourse.participants" => { "version" => 1, "caller" => { "agentId" => @third.id } },
      "concourse.sender" => { "version" => 1, "agentId" => @third.id }, "ticket" => "kept" }
  end

  def assert_snapshot(result)
    assert_equal participants, result.dig("metadata", "concourse.participants")
    input = result.fetch("history").find { |item| item["messageId"] == @input.wire_message_id }
    assert_equal sender(@caller), input.dig("metadata", "concourse.sender")
    assert_equal "kept", input.dig("metadata", "ticket")
  end

  def send_rpc(message, metadata: {})
    post "/a2a/#{@org.slug}/#{@recipient.qualified_handle}",
      params: { jsonrpc: "2.0", id: "participant-request", method: "SendMessage", params: {
        message: message, metadata: metadata, configuration: { returnImmediately: true }
      } }.to_json, headers: headers(@caller).merge("A2A-Version" => "1.0")
    assert_response :success
    response.parsed_body
  end
end
