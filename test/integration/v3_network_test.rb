require "test_helper"

class V3NetworkTest < ActionDispatch::IntegrationTest
  setup do
    @old_release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Network One", slug: "network-one")
    @elsewhere = Organization.create!(name: "Network Two", slug: "network-two")
    @caller = create_agent(@org, "net-sender")
    @recipient = create_agent(@org, "net-receiver")
    @outsider = create_agent(@elsewhere, "net-outsider")
    @network = @org.agents.find_by!(handle: "network-#{@org.id}")
    [ @caller, @recipient, @outsider ].each do |agent|
      stub_agent_token(agent.handle, client_id: agent.oauth_client_id, sub: agent.owner.ajent_sub)
    end
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @old_release
  end

  test "identity does not provision records and private card advertises actual skills without presence" do
    assert_no_difference [ -> { Agent.count }, -> { Task.count }, -> { Agent::Connection.count } ] do
      get "/api/identity", headers: headers(@caller)
      assert_response :success
      assert_equal 3, response.parsed_body["release_line"]
      assert_equal @network.qualified_handle, response.parsed_body["network_agent"]
    end
    assert_equal %w[concourse.presence concourse.delivery], A2a::Card.extended_for(@network)["skills"].map { |skill| skill["id"] }
    assert_empty A2a::Card.public_for(@network)["skills"]
    assert_not_includes A2a::Card.public_for(@network).to_json, "connected"
    assert_equal 1, @elsewhere.agents.where(owner: User.system).count
  end

  test "presence returns direct Message without surviving Task and preserves replay and context" do
    query = { "operation" => "presence", "agent" => @recipient.qualified_handle }
    body = nil
    assert_no_difference -> { Task.count } do
      body = network(query, id: "presence-query", context: "caller-context")
    end
    assert_nil body.dig("result", "task")
    message = body.dig("result", "message")
    assert_equal "ROLE_AGENT", message["role"]
    assert_equal "caller-context", message["contextId"]
    assert_nil message["taskId"]
    assert_equal "unknown", message.dig("parts", 0, "data", "state")
    connection = Agent::Connection.open!(@recipient, session_id: "session-one")
    assert_equal message, network(query, id: "presence-query", context: "caller-context").dig("result", "message")
    fresh = network(query).dig("result", "message", "parts", 0, "data")
    assert_equal "connected", fresh["state"]
    assert fresh["fresh"]
    assert_not_includes fresh.to_json, connection.id
    assert_not_includes fresh.to_json, "session-one"
    connection.close!
    assert_equal "disconnected", network(query).dig("result", "message", "parts", 0, "data", "state")
  end

  test "ordinary streaming network send is one Message result, never fake task events" do
    payload = message_payload({ "operation" => "presence", "agent" => @recipient.qualified_handle })
    assert_no_difference -> { Task.count } do
      rpc(@network, "SendStreamingMessage", payload)
      assert_response :success
      assert_equal "text/event-stream", response.media_type
      assert_includes response.body, '"message":'
      assert_not_includes response.body, '"task":'
      assert_not_includes response.body, '"statusUpdate":'
    end
  end

  test "lost-send reconciliation reports accepted separately from queued, running and completion" do
    sent = rpc(@recipient, "SendMessage", message_payload("peer work", id: "lost-send"))
    task_id = sent.dig("result", "task", "id")
    assert_equal "accepted", delivery("lost-send")["state"]
    connection = Agent::Connection.open!(@recipient, session_id: "pi-network")
    claim = SecureRandom.uuid
    env = { operation: "accept", id: claim, connectionId: connection.id, sessionId: connection.session_id, messageIds: [ "lost-send" ] }
    worker(task_id, delivery: env)
    assert_response :success
    assert_equal claim, response.parsed_body.dig("delivery", "id")
    assert_equal "queued", delivery("lost-send")["state"]
    assert_equal "TASK_STATE_SUBMITTED", delivery("lost-send")["taskStatus"]
    worker(task_id, delivery: env.merge(operation: "prompt"))
    assert_response :success
    assert_equal "delivered", delivery("lost-send")["state"]
    refused = rpc(@recipient, "CancelTask", { id: task_id })
    assert_equal A2a::Error::CODES[:task_not_cancelable], refused.dig("error", "code")
    worker(task_id, delivery: env.merge(operation: "start"))
    assert_response :success
    assert_equal "running", delivery("lost-send")["state"]
    settle = { delivery: env.merge(operation: "settle"), state: "TASK_STATE_COMPLETED", message: { parts: [ { text: "explicit recipient answer" } ] }, artifact: { parts: [ { data: { count: 2 } } ] } }
    worker(task_id, **settle)
    assert_response :success
    assert_equal "TASK_STATE_COMPLETED", delivery("lost-send")["taskStatus"]
    assert_equal "delivered", delivery("lost-send")["state"]
    assert_no_difference [ -> { Message.count }, -> { Artifact.count } ] do
      worker(task_id, **settle)
      assert_response :success
    end
    fetched = rpc(@recipient, "GetTask", { id: task_id })
    assert_equal "explicit recipient answer", fetched.dig("result", "status", "message", "parts", 0, "text")
    replay = rpc(@recipient, "SendMessage", message_payload("different body", id: "lost-send"))
    assert_equal task_id, replay.dig("result", "task", "id")
    assert_equal "TASK_STATE_COMPLETED", replay.dig("result", "task", "status", "state")
  end

  test "v3 denies malformed delivery and spoofed-role publication without changing task or content" do
    task = Task.open!(caller: @caller, recipient: @recipient)
    assert_no_difference -> { Message.count } do
      worker(task.id, delivery: {}, state: "TASK_STATE_COMPLETED", metadata: { "concourse.delivery" => "delivered", "concourse.via" => "owner" })
      assert_response :unprocessable_entity
      post worker_task_messages_path(task), params: { parts: [ { text: "forged" } ], delivery: { operation: "settle" } }.to_json, headers: headers(@recipient)
      assert_response :not_found
    end
    assert_equal "TASK_STATE_SUBMITTED", task.reload.state
    params = message_payload("peer")
    params[:message][:role] = "ROLE_AGENT"
    rpc(@recipient, "SendMessage", params)
    assert_equal A2a::Error::CODES[:invalid_params], response.parsed_body.dig("error", "code")
    params = message_payload("peer", id: "metadata-spoof")
    params[:message][:metadata] = { "concourse.caller" => @outsider.qualified_handle, "concourse.delivery" => { id: "fake" }, "ticket" => "test" }
    body = rpc(@recipient, "SendMessage", params)
    assert_equal({ "ticket" => "test", "concourse.sender" => { "version" => 1, "organizationId" => @org.id,
      "organization" => @org.slug, "agentId" => @caller.id, "handle" => @caller.qualified_handle } }, body.dig("result", "task", "history", 0, "metadata"))
  end

  test "cross-organization, nonparticipants, and removed parties cannot probe receipts or presence" do
    sent = rpc(@recipient, "SendMessage", message_payload("secret", id: "private-send"))
    task_id = sent.dig("result", "task", "id")
    assert_no_difference -> { Task.count } do
      network({ "operation" => "presence", "agent" => @outsider.qualified_handle })
      assert_equal A2a::Error::CODES[:task_not_found], response.parsed_body.dig("error", "code")
      network({ "operation" => "delivery", "taskId" => task_id }, caller: @outsider, network_agent: @elsewhere.agents.find_by!(handle: "network-#{@elsewhere.id}"))
      assert_equal A2a::Error::CODES[:task_not_found], response.parsed_body.dig("error", "code")
    end
    assert_equal "absent", delivery("not-sent")["state"]
    @org.memberships.find_by!(user: @recipient.owner).destroy!
    network({ "operation" => "delivery", "taskId" => task_id })
    assert_equal A2a::Error::CODES[:task_not_found], response.parsed_body.dig("error", "code")
    network({ "operation" => "delivery", "recipient" => @recipient.qualified_handle, "messageId" => "private-send" })
    assert_equal A2a::Error::CODES[:task_not_found], response.parsed_body.dig("error", "code")
  end

  test "receipt expiry is explicit and queries never regenerate expired work" do
    sent = rpc(@recipient, "SendMessage", message_payload("expire", id: "expired-send"))
    @org.tasks.find(sent.dig("result", "task", "id")).destroy!
    assert_equal "expired", delivery("expired-send")["state"]
    assert_no_difference -> { Task.count } do
      rpc(@recipient, "SendMessage", message_payload("expire", id: "expired-send"))
      assert_nil response.parsed_body["result"]
    end
  end

  test "arbitrary content and malformed network operations are invalid without retained tasks" do
    assert_no_difference [ -> { Task.count }, -> { RelayDelivery.count } ] do
      rpc(@network, "SendMessage", message_payload("summarize this"))
      assert_equal A2a::Error::CODES[:invalid_params], response.parsed_body.dig("error", "code")
      network({ "operation" => "presence", "agent" => @recipient.qualified_handle, "owner" => "forged" })
      assert_equal A2a::Error::CODES[:invalid_params], response.parsed_body.dig("error", "code")
    end
  end

  test "worker pagination is bounded keyset and accepts ordinary decimal query parameters" do
    expected = 3.times.map do |n|
      rpc(@recipient, "SendMessage", message_payload("page #{n}", id: "page-#{n}")).dig("result", "task", "id")
    end
    get "/agents/#{@recipient.id}/tasks", params: { pageSize: "2" }, headers: headers(@recipient)
    assert_response :success
    head = response.parsed_body
    assert_equal 2, head["pageSize"]
    assert_equal 2, head["tasks"].length
    assert head["nextPageToken"].present?
    get "/agents/#{@recipient.id}/tasks", params: { pageSize: "2", pageToken: head["nextPageToken"] }, headers: headers(@recipient)
    assert_response :success
    tail = response.parsed_body
    assert_equal "", tail["nextPageToken"]
    assert_equal expected.sort, (head["tasks"] + tail["tasks"]).map { |task| task["id"] }.sort
    %w[0 101 nonsense].each do |size|
      get "/agents/#{@recipient.id}/tasks", params: { pageSize: size }, headers: headers(@recipient)
      assert_response :unprocessable_entity
    end
  end

  test "worker settlement preserves multiple atomic artifacts and pending continuations cannot be discarded" do
    task_id = rpc(@recipient, "SendMessage", message_payload("batch", id: "batch-one")).dig("result", "task", "id")
    connection = Agent::Connection.open!(@recipient, session_id: "atomic-pi")
    envelope = { id: SecureRandom.uuid, connectionId: connection.id, sessionId: connection.session_id }
    worker(task_id, delivery: envelope.merge(operation: "accept", messageIds: [ "batch-one" ]))
    assert_response :success
    worker(task_id, delivery: envelope.merge(operation: "prompt"))
    assert_response :success
    worker(task_id, delivery: envelope.merge(operation: "start"))
    assert_response :success
    continuation = message_payload("new caller instruction", id: "batch-two")
    continuation[:message][:taskId] = task_id
    rpc(@recipient, "SendMessage", continuation)
    assert_response :success
    artifacts = [
      { name: "one", parts: [ { data: { evidence: 1 } } ], metadata: { source: "synthetic" }, extensions: [ "https://extension.invalid/evidence" ] },
      { name: "two", parts: [ { text: "second output" } ] }
    ]
    assert_no_difference [ -> { Message.count }, -> { Artifact.count } ] do
      worker(task_id, delivery: envelope.merge(operation: "settle"), state: "TASK_STATE_COMPLETED", artifacts: artifacts)
      assert_response :unprocessable_entity
    end
    assert_equal "TASK_STATE_WORKING", @org.tasks.find(task_id).state
    payload = { delivery: envelope.merge(operation: "settle"), state: "TASK_STATE_WORKING", message: { parts: [ { text: "explicit batch outcome" } ] }, artifacts: artifacts }
    worker(task_id, **payload)
    assert_response :success
    settled = response.parsed_body
    assert_equal "settled", settled.dig("delivery", "phase")
    assert_equal "TASK_STATE_WORKING", settled.dig("status", "state")
    assert_equal 2, settled["artifacts"].length
    assert_equal({ "source" => "synthetic" }, settled["artifacts"][0]["metadata"])
    assert_equal [ "https://extension.invalid/evidence" ], settled["artifacts"][0]["extensions"]
    assert_no_difference [ -> { Message.count }, -> { Artifact.count } ] do
      worker(task_id, **payload)
      assert_response :success
    end
    changed = payload.merge(artifacts: [ { parts: [ { text: "different result" } ] } ])
    assert_no_difference [ -> { Message.count }, -> { Artifact.count } ] do
      worker(task_id, **changed)
      assert_response :unprocessable_entity
    end
    get "/agents/#{@recipient.id}/tasks", headers: headers(@recipient)
    assert_response :success
    assert_includes response.parsed_body["tasks"].map { |task| task["id"] }, task_id
  end

  test "malformed plural artifacts and ambiguous singular plural input commit nothing" do
    task_id = rpc(@recipient, "SendMessage", message_payload("atomic", id: "atomic-first")).dig("result", "task", "id")
    connection = Agent::Connection.open!(@recipient, session_id: "atomic-invalid")
    envelope = { id: SecureRandom.uuid, connectionId: connection.id, sessionId: connection.session_id }
    %w[accept prompt start].each do |operation|
      worker(task_id, delivery: envelope.merge(operation: operation, **(operation == "accept" ? { messageIds: [ "atomic-first" ] } : {})))
      assert_response :success
    end
    good = { parts: [ { text: "valid first artifact" } ] }
    [ { artifacts: [ good, { artifactId: "spoofed", parts: [ { text: "invalid" } ] } ] }, { artifacts: [ good ], artifact: good } ].each do |body|
      assert_no_difference [ -> { Message.count }, -> { Artifact.count } ] do
        worker(task_id, delivery: envelope.merge(operation: "settle"), state: "TASK_STATE_COMPLETED", message: { parts: [ { text: "must roll back" } ] }, **body)
        assert_response :unprocessable_entity
      end
      assert_equal "running", @org.tasks.find(task_id).task_deliveries.find(envelope[:id]).phase
      assert_equal "TASK_STATE_WORKING", @org.tasks.find(task_id).state
    end
  end

  test "singular artifact has the same validated fields and digest as a plural item" do
    task_id = rpc(@recipient, "SendMessage", message_payload("single", id: "single-artifact")).dig("result", "task", "id")
    connection = Agent::Connection.open!(@recipient, session_id: "single-artifact-pi")
    envelope = { id: SecureRandom.uuid, connectionId: connection.id, sessionId: connection.session_id }
    %w[accept prompt start].each do |operation|
      worker(task_id, delivery: envelope.merge(operation: operation, **(operation == "accept" ? { messageIds: [ "single-artifact" ] } : {})))
      assert_response :success
    end
    artifact = { parts: [ { text: "one output" } ], metadata: { ticket: "synthetic" }, extensions: [ "urn:example:result" ] }
    assert_no_difference -> { Artifact.count } do
      worker(task_id, delivery: envelope.merge(operation: "settle"), state: "TASK_STATE_COMPLETED", artifact: artifact.merge(artifactId: "not-authorized"))
      assert_response :unprocessable_entity
    end
    worker(task_id, delivery: envelope.merge(operation: "settle"), state: "TASK_STATE_COMPLETED", artifact: artifact)
    assert_response :success
    stored = response.parsed_body["artifacts"].sole
    assert_equal({ "ticket" => "synthetic" }, stored["metadata"])
    assert_equal [ "urn:example:result" ], stored["extensions"]
    assert_no_difference -> { Artifact.count } do
      worker(task_id, delivery: envelope.merge(operation: "settle"), state: "TASK_STATE_COMPLETED", artifact: artifact.merge(metadata: { ticket: "changed" }))
      assert_response :unprocessable_entity
    end
  end

  test "equal timestamp keyset sweeps survive status churn expose new work at head and hide removed callers" do
    stamp = 1.hour.ago
    ids = 6.times.map do |n|
      id = rpc(@recipient, "SendMessage", message_payload("fair #{n}", id: "fair-#{n}")).dig("result", "task", "id")
      @org.tasks.find(id).update_columns(created_at: stamp)
      id
    end
    get "/agents/#{@recipient.id}/tasks", params: { pageSize: "2" }, headers: headers(@recipient)
    assert_response :success
    page = response.parsed_body
    seen = page["tasks"].map { |task| task["id"] }
    @org.tasks.find((ids - seen).first).update_columns(state: "TASK_STATE_WORKING", status_at: 2.minutes.from_now)
    fresh = rpc(@recipient, "SendMessage", message_payload("fresh head", id: "fair-fresh")).dig("result", "task", "id")
    while page["nextPageToken"].present?
      get "/agents/#{@recipient.id}/tasks", params: { pageSize: "2", pageToken: page["nextPageToken"] }, headers: headers(@recipient)
      assert_response :success
      page = response.parsed_body
      seen.concat(page["tasks"].map { |task| task["id"] })
    end
    assert_equal ids.sort, seen.sort
    assert_equal seen.size, seen.uniq.size
    assert_not_includes seen, fresh
    get "/agents/#{@recipient.id}/tasks", params: { pageSize: "50" }, headers: headers(@recipient)
    assert_response :success
    assert_includes response.parsed_body["tasks"].map { |task| task["id"] }, fresh
    @org.memberships.find_by!(user: @caller.owner).destroy!
    get "/agents/#{@recipient.id}/tasks", params: { pageSize: "50" }, headers: headers(@recipient)
    assert_response :success
    assert_empty response.parsed_body["tasks"]
  end

  private

  def create_agent(org, name)
    owner = User.create!(handle: name, ajent_sub: name, organizations: [ org ])
    Agent.create!(owner: owner, organization: org, handle: name, oauth_client_id: "client-#{name}")
  end

  def headers(agent)
    { "Authorization" => "Bearer #{agent.handle}", "CONTENT_TYPE" => "application/json", "A2A-Version" => "1.0" }
  end

  def message_payload(data, id: SecureRandom.uuid, context: nil)
    part = data.is_a?(Hash) ? { mediaType: "application/json", data: data } : { text: data }
    message = { messageId: id, role: "ROLE_USER", parts: [ part ] }
    message[:contextId] = context if context
    { message: message, configuration: { returnImmediately: true } }
  end

  def rpc(recipient, method, params, caller: @caller)
    post "/a2a/#{recipient.organization.slug}/#{recipient.qualified_handle}", params: { jsonrpc: "2.0", id: "rpc-id", method: method, params: params }.to_json, headers: headers(caller)
    response.media_type == "application/json" ? response.parsed_body : nil
  end

  def network(data, id: SecureRandom.uuid, context: nil, caller: @caller, network_agent: @network)
    rpc(network_agent, "SendMessage", message_payload(data, id: id, context: context), caller: caller)
  end

  def delivery(message_id)
    network({ "operation" => "delivery", "recipient" => @recipient.qualified_handle, "messageId" => message_id }).dig("result", "message", "parts", 0, "data")
  end

  def worker(task_id, **payload)
    patch "/tasks/#{task_id}", params: payload.to_json, headers: headers(@recipient)
  end
end
