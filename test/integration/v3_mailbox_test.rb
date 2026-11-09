require "test_helper"

class V3MailboxTest < ActionDispatch::IntegrationTest
  setup do
    @old_release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Mailbox", slug: "mailbox")
    @caller = create_agent(@org, "mail-sender")
    @recipient = create_agent(@org, "mail-recipient")
    @third_party = create_agent(@org, "mail-third")
    @other_org = Organization.create!(name: "Other mailbox", slug: "other-mailbox")
    @outsider = create_agent(@other_org, "mail-outsider")
    @task = Task.open!(caller: @caller, recipient: @recipient)
    @input = Message.record!(task: @task, role: "ROLE_USER", sender: @caller,
      message_id: "mail-input", parts: [ { "text" => "peer request" } ])
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @old_release
  end

  test "ordinary recipient explicitly answers without a connection or claim with normalized plural artifacts" do
    artifacts = [
      { name: "evidence", description: "local result", parts: [ { data: { count: 2 }, media_type: "application/json" } ],
        metadata: { source: "synthetic" }, extensions: [ "urn:example:evidence" ] },
      { parts: [ { text: "second output", media_type: "text/plain" } ] }
    ]
    assert_no_difference [ -> { Agent::Connection.count }, -> { TaskDelivery.count } ] do
      assert_difference -> { Artifact.count }, 2 do
        update_task(state: "TASK_STATE_COMPLETED", message: { parts: [ { text: "actual answer", media_type: "text/plain" } ] }, artifacts: artifacts)
        assert_response :success
      end
    end
    body = response.parsed_body
    assert_equal @task.id, body["id"]
    assert_equal "TASK_STATE_COMPLETED", body.dig("status", "state")
    assert_not body.key?("delivery")
    assert_equal({ "text" => "actual answer", "mediaType" => "text/plain" }, body.dig("status", "message", "parts", 0))
    assert_equal "ROLE_AGENT", body.dig("status", "message", "role")
    assert_equal 2, body["artifacts"].size
    assert_equal "evidence", body["artifacts"][0]["name"]
    assert_equal "local result", body["artifacts"][0]["description"]
    assert_equal({ "data" => { "count" => 2 }, "mediaType" => "application/json" }, body["artifacts"][0]["parts"][0])
    assert_equal({ "source" => "synthetic" }, body["artifacts"][0]["metadata"])
    assert_equal [ "urn:example:evidence" ], body["artifacts"][0]["extensions"]
    assert_equal "text/plain", body["artifacts"][1]["parts"][0]["mediaType"]
    assert_equal @recipient.id, @task.messages.where(role: "ROLE_AGENT").sole.sender_agent_id
  end

  test "transport opening closing and inbox reads never select an outcome or prevent an ordinary reply" do
    connection = Agent::Connection.open!(@recipient, session_id: "mailbox-pi")
    connection.close!
    assert_no_difference [ -> { TaskEvent.count }, -> { TaskDelivery.count }, -> { Message.count } ] do
      2.times do
        inbox
        assert_equal [ @task.id ], response.parsed_body["tasks"].pluck("id")
      end
    end
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
    update_task(state: "TASK_STATE_WORKING")
    assert_response :success
    assert_equal "TASK_STATE_WORKING", @task.reload.state
    assert_not connection.reload.active?
    update_task(state: "TASK_STATE_FAILED", message: { parts: [ { text: "explicit failure" } ] })
    assert_response :success
    assert_equal "TASK_STATE_FAILED", @task.reload.state
  end

  test "caller same-tenant third party and cross-tenant outsider cannot reply or claim owner authority" do
    assert_no_difference [ -> { Message.count }, -> { Artifact.count }, -> { TaskEvent.count } ] do
      [ @caller, @third_party, @outsider ].each do |agent|
        update_task(agent: agent, state: "TASK_STATE_COMPLETED", message: { parts: [ { text: "forged" } ] }, owner: @recipient.owner_id)
        assert_response :not_found
      end
    end
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
  end

  test "ordinary replies refuse terminal tasks and recipient canceled or submitted states atomically" do
    [ "TASK_STATE_CANCELED", "TASK_STATE_SUBMITTED" ].each do |state|
      assert_no_difference [ -> { Message.count }, -> { Artifact.count }, -> { TaskEvent.count } ] do
        update_task(state: state, message: { parts: [ { text: "must not persist" } ] })
        assert_response :unprocessable_entity
      end
      assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
    end
    @task.transition_to!("TASK_STATE_WORKING", by: @recipient)
    update_task(state: "TASK_STATE_SUBMITTED")
    assert_response :unprocessable_entity
    assert_equal "TASK_STATE_WORKING", @task.reload.state
    @task.transition_to!("TASK_STATE_COMPLETED", by: @recipient)
    assert_no_difference [ -> { Message.count }, -> { Artifact.count }, -> { TaskEvent.count } ] do
      update_task(state: "TASK_STATE_WORKING", artifacts: [ { parts: [ { text: "too late" } ] } ])
      assert_response :unprocessable_entity
    end
  end

  test "ordinary replies preserve fresh participant admission inbox route and internal owner authorization" do
    [ @caller, @recipient ].each do |removed|
      membership = @org.memberships.find_by!(user: removed.owner)
      membership.destroy!
      assert_raises(A2a::Error) { A2a::Exchange.reply(agent: @recipient, task_id: @task.id, state: "TASK_STATE_COMPLETED") }
      @org.memberships.create!(user: removed.owner)
    end
    assert_raises(A2a::Error) do
      A2a::Exchange.reply(agent: @recipient, task_id: @task.id, owner: @caller.owner, state: "TASK_STATE_COMPLETED")
    end
    %w[native held].each do |route|
      task = Task.open!(caller: @caller, recipient: @recipient)
      task.update_columns(execution_route: route)
      assert_raises(A2a::Error) { A2a::Exchange.reply(agent: @recipient, task_id: task.id, state: "TASK_STATE_COMPLETED") }
    end
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
  end

  test "ordinary singular artifacts and message-only replies use the same normalization without delivery" do
    post worker_task_messages_path(@task), params: { parts: [ { text: "progress", media_type: "text/plain" } ] }.to_json, headers: headers(@recipient)
    assert_response :success
    assert_equal "text/plain", response.parsed_body.dig("parts", 0, "mediaType")
    update_task(artifact: { parts: [ { text: "one output" } ], metadata: { ticket: "test" }, extensions: [ "urn:example:result" ] })
    assert_response :success
    artifact = response.parsed_body["artifacts"].sole
    assert_equal({ "ticket" => "test" }, artifact["metadata"])
    assert_equal [ "urn:example:result" ], artifact["extensions"]
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
  end

  test "ordinary malformed parts artifacts and ambiguous singular plural input commit nothing" do
    good = { parts: [ { text: "valid" } ] }
    [ { message: { parts: [ { text: "invalid", data: {} } ] } },
      { artifacts: [ good, good.merge(artifactId: "forged") ] },
      { artifacts: [ good ], artifact: good }, { artifact: [] }, { artifacts: {} },
      { artifacts: [ { parts: [ { text: "invalid", metadata: "bad" } ] } ] } ].each do |payload|
      assert_no_difference [ -> { Message.count }, -> { Artifact.count }, -> { TaskEvent.count } ] do
        update_task(state: "TASK_STATE_COMPLETED", **payload)
        assert_response :unprocessable_entity
      end
      assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
    end
  end

  test "all genuine caller content stays discoverable across unfinished claims and settled WORKING continuations without inbox side effects" do
    connection = Agent::Connection.open!(@recipient, session_id: "experimental-pi")
    envelope = { id: SecureRandom.uuid, connectionId: connection.id, sessionId: connection.session_id }
    %w[accept prompt start].each do |operation|
      update_task(delivery: envelope.merge(operation: operation, **(operation == "accept" ? { messageIds: [ @input.wire_message_id ] } : {})))
      assert_response :success
    end
    continuation = Message.record!(task: @task.reload, role: "ROLE_USER", sender: @caller,
      message_id: "mail-continuation", parts: [ { "text" => "more peer input" } ])
    update_task(delivery: envelope.merge(operation: "settle"), state: "TASK_STATE_WORKING", message: { parts: [ { text: "first batch" } ] })
    assert_response :success
    envelope[:id] = SecureRandom.uuid
    %w[accept prompt start settle].each do |operation|
      extra = operation == "accept" ? { messageIds: [ continuation.wire_message_id ] } : {}
      outcome = operation == "settle" ? { state: "TASK_STATE_WORKING", message: { parts: [ { text: "still ongoing" } ] } } : {}
      update_task(delivery: envelope.merge(operation: operation, **extra), **outcome)
      assert_response :success
    end
    connection.close!
    assert_equal 0, @task.reload.unclaimed_caller_messages.count
    assert_no_difference [ -> { TaskEvent.count }, -> { TaskDelivery.count }, -> { Message.count } ] do
      2.times do
        inbox
        assert_equal 1, response.parsed_body["tasks"].size
        task = response.parsed_body["tasks"].sole
        assert_equal @task.id, task["id"]
        assert_equal "TASK_STATE_WORKING", task.dig("status", "state")
        assert_equal [ "mail-input", "mail-continuation" ], task["history"].select { |message| message["role"] == "ROLE_USER" }.pluck("messageId")
      end
    end
    assert_equal %w[settled settled], @task.task_deliveries.order(:created_at).pluck(:phase)
    assert_equal "TASK_STATE_WORKING", @task.reload.state
  end

  test "reading an unfinished claimed task does not complete or mutate it and mailbox excludes nongenuine input and terminals" do
    connection = Agent::Connection.open!(@recipient, session_id: "queued-pi")
    update_task(delivery: { operation: "accept", id: SecureRandom.uuid, connectionId: connection.id,
      sessionId: connection.session_id, messageIds: [ @input.wire_message_id ] })
    assert_response :success
    connection.close!
    no_input = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: no_input, role: "ROLE_AGENT", sender: @recipient, parts: [ { "text" => "not caller input" } ])
    forged = Task.open!(caller: @caller, recipient: @recipient)
    Message.create!(task: forged, role: "ROLE_USER", sender_agent: @third_party, parts: [ { "text" => "not genuine caller" } ])
    terminal = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: terminal, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "finished" } ])
    terminal.transition_to!("TASK_STATE_COMPLETED", by: @recipient)
    assert_no_difference [ -> { TaskEvent.count }, -> { TaskDelivery.count }, -> { Message.count } ] do
      inbox
      assert_equal [ @task.id ], response.parsed_body["tasks"].pluck("id")
    end
    assert_equal "queued", @task.task_deliveries.sole.phase
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
  end

  private

  def create_agent(org, handle)
    owner = User.create!(handle: handle, ajent_sub: handle, organizations: [ org ])
    agent = Agent.create!(owner: owner, organization: org, handle: handle, oauth_client_id: "client-#{handle}")
    stub_agent_token(handle, client_id: agent.oauth_client_id, sub: owner.ajent_sub)
    agent
  end

  def headers(agent)
    { "Authorization" => "Bearer #{agent.handle}", "CONTENT_TYPE" => "application/json" }
  end

  def update_task(agent: @recipient, **payload)
    patch worker_task_path(@task), params: payload.to_json, headers: headers(agent)
  end

  def inbox
    get "/agents/#{@recipient.id}/tasks", headers: headers(@recipient)
    assert_response :success
  end
end
