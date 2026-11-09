require "test_helper"

class ReplyOutputCorrelationTest < ActionDispatch::IntegrationTest
  setup do
    @release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Reply correlation", slug: "reply-correlation")
    @caller = create_agent("correlation-caller")
    @recipient = create_agent("correlation-recipient")
    @task = Task.open!(caller: @caller, recipient: @recipient)
    @input = Message.record!(task: @task, role: "ROLE_USER", sender: @caller,
      message_id: "wire-first", parts: [ { "text" => "first request" } ])
    @pair = @task.latest_caller_input
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @release
  end

  test "fenced reply durably binds exactly its new message artifact and status event" do
    update_task(expected_caller_input: @pair, **outcome)
    assert_response :success
    body = response.parsed_body
    event = @task.events.where.not(state: nil).order(:id).last
    binding = expected_binding(@pair, event)
    output = body.dig("metadata", "concourse.output")
    assert_equal @pair, output["callerInput"]
    assert_equal event.id.to_s, output.fetch("statusEventId")
    assert_equal [ @task.reload.status_message.wire_message_id ], output.fetch("messageIds")
    assert_equal [ @task.artifacts.sole.artifact_id ], output.fetch("artifactIds")
    assert_equal binding, body.dig("status", "message", "metadata", "concourse.reply_to")
    assert_equal binding, body.fetch("artifacts").sole.dig("metadata", "concourse.reply_to")
    assert_equal binding, body.fetch("history").last.dig("metadata", "concourse.reply_to")
    assert_not event.update(payload: {})
    assert_equal @pair, @task.latest_caller_input
  end

  test "later caller input and tied timestamps cannot reassociate prior content or retained status text" do
    freeze_time do
      update_task(expected_caller_input: @pair, **outcome)
      assert_response :success
      original = response.parsed_body.dig("status", "message", "metadata", "concourse.reply_to")
      @task.with_lock do
        Message.record!(task: @task, role: "ROLE_USER", sender: @caller,
          message_id: "wire-second", parts: [ { "text" => "second request" } ])
      end
      latest = @task.latest_caller_input
      get "/api/tasks/#{@task.id}", headers: headers
      assert_response :success
      assert_equal latest, response.parsed_body.dig("metadata", "concourse.caller_input")
      assert_equal @pair, response.parsed_body.dig("metadata", "concourse.output", "callerInput")
      update_task(expected_caller_input: latest, state: "TASK_STATE_WORKING")
      assert_response :success
      body = response.parsed_body
      assert_equal latest, body.dig("metadata", "concourse.output", "callerInput")
      assert_empty body.dig("metadata", "concourse.output", "messageIds")
      assert_empty body.dig("metadata", "concourse.output", "artifactIds")
      assert_equal original, body.dig("status", "message", "metadata", "concourse.reply_to")
      assert_equal original, body.fetch("artifacts").sole.dig("metadata", "concourse.reply_to")
      assert_not_equal original.fetch("statusEventId"), body.dig("metadata", "concourse.output", "statusEventId")
    end
  end

  test "artifact only replies and standalone serialization retain their original binding" do
    update_task(expected_caller_input: @pair, artifacts: outcome.fetch(:artifacts))
    assert_response :success
    body = response.parsed_body
    binding = body.fetch("artifacts").sole.dig("metadata", "concourse.reply_to")
    assert_kind_of Hash, binding
    assert_equal @pair, binding.fetch("callerInput")
    assert_empty body.dig("metadata", "concourse.output", "messageIds")
    assert_equal binding, A2a::Serializer.artifact(@task.artifacts.sole).dig("metadata", "concourse.reply_to")
    assert_nil body.dig("status", "message")
  end

  test "ordinary unfenced replies remain unbound and never inherit a previous fence" do
    update_task(expected_caller_input: @pair, **outcome)
    assert_response :success
    update_task(message: { parts: [ { text: "unfenced answer" } ] }, artifacts: outcome.fetch(:artifacts))
    assert_response :success
    body = response.parsed_body
    assert_nil body.dig("metadata", "concourse.output", "callerInput")
    assert_nil body.dig("status", "message", "metadata", "concourse.reply_to")
    assert_nil body.fetch("artifacts").last.dig("metadata", "concourse.reply_to")
    assert_equal 1, body.fetch("history").count { |message| message.dig("metadata", "concourse.reply_to") }
  end

  test "forged stored metadata cannot impersonate server recorded correlation" do
    forged = { "concourse.reply_to" => expected_binding(@pair, @task.events.first), "ordinary" => "preserved" }
    user = Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { text: "user" } ], metadata: forged)
    agent = Message.record!(task: @task, role: "ROLE_AGENT", sender: @recipient, parts: [ { text: "agent" } ], metadata: forged)
    artifact = Artifact.record!(task: @task, by: @recipient, parts: [ { text: "artifact" } ], metadata: forged)
    [ A2a::Serializer.message(user), A2a::Serializer.message(agent), A2a::Serializer.artifact(artifact) ].each do |item|
      assert_nil item.dig("metadata", "concourse.reply_to")
      assert_equal "preserved", item.dig("metadata", "ordinary")
    end
  end

  test "stale and invalid replies leave no binding or partial output" do
    @task.with_lock { Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { text: "new input" } ]) }
    assert_no_difference [ -> { Message.count }, -> { Artifact.count }, -> { TaskEvent.count } ] do
      update_task(expected_caller_input: @pair, **outcome)
      assert_response :conflict
      update_task(expected_caller_input: @task.latest_caller_input, **outcome.merge(state: "TASK_STATE_UNKNOWN"))
      assert_response :unprocessable_entity
    end
    assert_empty @task.events.where(kind: "reply")
  end

  test "MCP reply uses the same durable association" do
    token = "correlation-mcp"
    stub_agent_token(token, client_id: @recipient.oauth_client_id, sub: @recipient.owner.ajent_sub,
      resource: :mcp, organization: @org)
    post "/mcp", params: { jsonrpc: "2.0", id: "correlation", method: "tools/call", params: { name: "reply",
      arguments: { task_id: @task.id, expected_caller_input: @pair, text: "MCP answer", artifact_text: "MCP artifact",
        state: "TASK_STATE_WORKING" } } }.to_json,
      headers: headers.merge("Authorization" => "Bearer #{token}", "ACCEPT" => "application/json")
    assert_response :ok
    result = response.parsed_body.fetch("result")
    assert_not result["isError"]
    body = result.fetch("structuredContent")
    assert_equal @pair, body.dig("metadata", "concourse.output", "callerInput")
    assert_equal body.dig("status", "message", "metadata", "concourse.reply_to"),
      body.fetch("artifacts").sole.dig("metadata", "concourse.reply_to")
  end

  test "status only replies expose their own binding in snapshots and streamed status metadata" do
    stream = A2a::Stream.task(@task, viewer: @caller)
    update_task(expected_caller_input: @pair, state: "TASK_STATE_COMPLETED")
    assert_response :success
    output = response.parsed_body.dig("metadata", "concourse.output")
    assert_equal @pair, output["callerInput"]
    assert_empty output.fetch("messageIds")
    assert_empty output.fetch("artifactIds")
    events = []
    A2a::Exchange.with_limits(poll: 0.01, stream: 1) { stream.each { |event| events << event } }
    update = events.last.fetch("statusUpdate")
    assert_equal "TASK_STATE_COMPLETED", update.dig("status", "state")
    assert_equal expected_binding(@pair, @task.events.order(:id).last), update.dig("metadata", "concourse.reply_to")
    assert_nil update.dig("status", "message")
  end

  test "new fenced questions remain distinct from an answered retained question" do
    freeze_time do
      question = { state: "TASK_STATE_INPUT_REQUIRED", message: { parts: [ { text: "first question" } ] } }
      update_task(expected_caller_input: @pair, **question)
      assert_response :success
      original_id = response.parsed_body.dig("status", "message", "messageId")
      @task.with_lock { Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { text: "answer" } ]) }
      latest = @task.latest_caller_input
      get "/api/tasks/#{@task.id}", headers: headers
      assert_empty response.parsed_body.dig("metadata", "concourse.output", "messageIds")
      update_task(expected_caller_input: latest, **question)
      assert_response :success
      body = response.parsed_body
      new_id = body.dig("status", "message", "messageId")
      assert_not_equal original_id, new_id
      assert_equal [ new_id ], body.dig("metadata", "concourse.output", "messageIds")
      assert_equal latest, body.dig("metadata", "concourse.output", "callerInput")
      original = body.fetch("history").find { |message| message["messageId"] == original_id }
      assert_equal @pair, original.dig("metadata", "concourse.reply_to", "callerInput")
    end
  end

  test "owner replies cannot become recipient fenced output even with an internal expected pair" do
    Current.set(user: @recipient.owner) do
      result = A2a::Exchange.reply(agent: @recipient, task_id: @task.id, parts: [ { "text" => "owner answer" } ],
        state: "TASK_STATE_WORKING", owner: @recipient.owner, expected_caller_input: @pair)
      body = A2a::Serializer.task(result)
      assert_nil body.dig("metadata", "concourse.output", "callerInput")
      assert_nil body.dig("status", "message", "metadata", "concourse.reply_to")
      assert_empty result.events.where(kind: "reply")
    end
  end

  test "caller cancellation does not inherit an earlier recipient fence" do
    update_task(expected_caller_input: @pair, state: "TASK_STATE_INPUT_REQUIRED", message: { parts: [ { text: "question" } ] })
    assert_response :success
    @task.reload.cancel_by_caller!(by: @caller)
    body = A2a::Serializer.task(@task.reload)
    assert_equal "TASK_STATE_CANCELED", body.dig("status", "state")
    assert_nil body.dig("metadata", "concourse.output", "callerInput")
    assert_equal @pair, body.fetch("history").last.dig("metadata", "concourse.reply_to", "callerInput")
  end

  test "legacy native and held serialization cannot manufacture this inbox assertion" do
    update_task(expected_caller_input: @pair, **outcome)
    assert_response :success
    %w[native held].each do |route|
      @task.update_columns(execution_route: route)
      assert_nil A2a::Serializer.message(@task.reload.status_message).dig("metadata", "concourse.reply_to")
      assert_nil A2a::Serializer.artifact(@task.artifacts.sole).dig("metadata", "concourse.reply_to")
    end
    @task.update_columns(execution_route: "inbox")
    Rails.application.config.x.concourse.release_line = 2
    assert_nil A2a::Serializer.message(@task.reload.status_message).dig("metadata", "concourse.reply_to")
    assert_nil A2a::Serializer.artifact(@task.artifacts.sole).dig("metadata", "concourse.reply_to")
  end

  test "an exception cannot carry transient reply evidence into a later status write" do
    assert_raises(RuntimeError) do
      @task.with_reply_output({ "version" => 1, "callerInput" => @pair, "messageIds" => [], "artifactIds" => [] }) { raise "rollback" }
    end
    @task.transition_to!("TASK_STATE_WORKING", by: @recipient)
    assert_empty @task.events.where(kind: "reply")
    assert_nil A2a::Serializer.task(@task).dig("metadata", "concourse.output", "callerInput")
  end

  test "stream replay keeps each message artifact and status bound across later input" do
    freeze_time do
      stream = A2a::Stream.task(@task, viewer: @caller)
      update_task(expected_caller_input: @pair, **outcome)
      assert_response :success
      first = response.parsed_body.dig("status", "message", "metadata", "concourse.reply_to")
      assert_kind_of Hash, first
      @task.with_lock { Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { text: "next input" } ]) }
      latest = @task.latest_caller_input
      update_task(expected_caller_input: latest, **outcome.merge(state: "TASK_STATE_COMPLETED"))
      assert_response :success
      second = response.parsed_body.dig("status", "message", "metadata", "concourse.reply_to")
      assert_not_equal first, second
      events = []
      A2a::Exchange.with_limits(poll: 0.01, stream: 1) { stream.each { |event| events << event } }
      statuses = events.filter_map { |event| event && event["statusUpdate"] }
      artifacts = events.filter_map { |event| event && event["artifactUpdate"] }
      assert_equal [ first, second ], statuses.map { |event| event.dig("metadata", "concourse.reply_to") }
      assert_equal [ first, second ], statuses.map { |event| event.dig("status", "message", "metadata", "concourse.reply_to") }
      assert_equal [ first, second ], artifacts.map { |event| event.dig("artifact", "metadata", "concourse.reply_to") }
      assert_equal @pair, first.fetch("callerInput")
      assert_equal latest, second.fetch("callerInput")
    end
  end

  private

  def create_agent(handle)
    owner = User.create!(handle: handle, ajent_sub: handle, organizations: [ @org ])
    agent = Agent.create!(owner: owner, organization: @org, handle: handle, oauth_client_id: "client-#{handle}")
    stub_agent_token(handle, client_id: agent.oauth_client_id, sub: owner.ajent_sub, organization: @org)
    agent
  end

  def headers
    { "Authorization" => "Bearer #{@recipient.handle}", "CONTENT_TYPE" => "application/json", "Concourse-Organization" => @org.slug }
  end

  def update_task(**payload)
    patch "/tasks/#{@task.id}", params: payload.to_json, headers: headers
  end

  def outcome
    { state: "TASK_STATE_WORKING", message: { parts: [ { text: "answer" } ] },
      artifacts: [ { parts: [ { text: "artifact" } ] } ] }
  end

  def expected_binding(pair, event)
    { "version" => 1, "callerInput" => pair, "statusEventId" => event.id.to_s }
  end
end
