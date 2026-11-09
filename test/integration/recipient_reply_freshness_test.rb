require "test_helper"

class RecipientReplyFreshnessTest < ActionDispatch::IntegrationTest
  setup do
    @release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Fresh replies", slug: "fresh-replies")
    @caller = create_agent(@org, "fresh-caller")
    @recipient = create_agent(@org, "fresh-recipient")
    @third = create_agent(@org, "fresh-third")
    other = Organization.create!(name: "Other replies", slug: "other-replies")
    @outsider = create_agent(other, "fresh-outsider")
    @task = Task.open!(caller: @caller, recipient: @recipient)
    @input = Message.create!(task: @task, role: "ROLE_USER", sender_agent: @caller,
      message_id: "ffffffff-ffff-4fff-8fff-ffffffffffff", client_message_id: "wire-old",
      parts: [ { "text" => "old request" } ])
    @pair = @task.latest_caller_input
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @release
  end

  test "GET exposes an opaque causal string bound to the wire ID not the internal primary key" do
    event = @task.events.where(kind: "caller_input").sole
    assert_equal({ "message_id" => @input.message_id }, event.payload)
    assert_equal({ "cursor" => event.id.to_s, "messageId" => "wire-old" }, @pair)
    assert_not_equal @input.message_id, @pair.fetch("messageId")
    [ "/api/tasks/#{@task.id}", "/agents/#{@recipient.id}/tasks", "/api/next_task?wait=0" ].each do |path|
      assert_unchanged do
        get path, headers: headers(@recipient)
        assert_response :success
      end
      body = response.parsed_body
      snapshot = body["tasks"]&.sole || body["task"] || body
      assert_equal @pair, snapshot.dig("metadata", "concourse.caller_input")
    end
  end

  test "equal timestamp reverse UUID caller append after GET and identity preflight refuses old failure atomically" do
    get "/api/tasks/#{@task.id}", headers: headers(@recipient)
    pair = response.parsed_body.dig("metadata", "concourse.caller_input")
    get "/api/identity", headers: headers(@recipient)
    assert_response :success
    append_tied_input
    # This is the real counterexample: history puts the newer input first.
    assert_equal [ "wire-new", "wire-old" ], A2a::Serializer.task(@task).fetch("history").pluck("messageId")
    assert_operator @task.latest_caller_input.fetch("cursor").to_i, :>, pair.fetch("cursor").to_i
    assert_unchanged do
      update_task(expected_caller_input: pair, **outcome)
      assert_stale
    end
  end

  test "append after Exchange identity and visibility preflight is rechecked under the task lock" do
    exchange = A2a::Exchange.new(@recipient)
    locate = exchange.method(:locate)
    append = method(:append_tied_input)
    capture = method(:snapshot)
    verify = ->(before, locked) { assert locked; assert_equal before, snapshot }
    exchange.define_singleton_method(:locate) do |*args, **kwargs|
      task = locate.call(*args, **kwargs)
      append.call
      before_reply = capture.call
      locked = false
      lock = task.method(:lock!)
      latest = task.method(:latest_caller_input)
      task.define_singleton_method(:lock!) { lock.call.tap { locked = true } }
      task.define_singleton_method(:latest_caller_input) do
        verify.call(before_reply, locked)
        latest.call
      end
      task
    end
    assert_raises(A2a::Exchange::StaleReply) do
      exchange.reply(@task.id, expected_caller_input: @pair, parts: [ { text: "old failure" } ],
        state: "TASK_STATE_FAILED", artifacts: [ { parts: [ { text: "old artifact" } ] } ])
    end
    # Exchange rolls its transaction back, including the synthetic concurrent append.
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
    assert_equal 1, @task.messages.count
  end

  test "matching pair atomically records message state and artifact and recipient progress does not advance it" do
    update_task(expected_caller_input: @pair, message: { parts: [ { text: "progress" } ] })
    assert_response :success
    assert_equal @pair, @task.latest_caller_input
    assert_difference -> { Message.count }, 1 do
      assert_difference -> { Artifact.count }, 1 do
        assert_difference -> { TaskEvent.count }, 2 do
          update_task(expected_caller_input: @pair, **outcome.merge(state: "TASK_STATE_COMPLETED"))
          assert_response :success
        end
      end
    end
    assert_equal "TASK_STATE_COMPLETED", @task.reload.state
    assert_equal "old failure", @task.status_message.parts.sole.fetch("text")
    assert_equal "old artifact", @task.artifacts.sole.parts.sole.fetch("text")
    assert_equal @pair, response.parsed_body.dig("metadata", "concourse.caller_input")
    assert_unchanged do
      update_task(expected_caller_input: @pair, **outcome)
      assert_response :unprocessable_entity
    end
  end

  test "no input event or a deleted bound message omits evidence and refuses a supplied pair" do
    @task.events.where(kind: "caller_input").delete_all
    assert_nil @task.latest_caller_input
    assert_unchanged do
      update_task(expected_caller_input: @pair, **outcome)
      assert_stale
    end
    @task.events.create!(kind: "caller_input", payload: { "message_id" => @input.message_id })
    @input.destroy!
    assert_nil @task.latest_caller_input
    assert_unchanged do
      update_task(expected_caller_input: @pair, **outcome)
      assert_stale
    end
  end

  test "matching evidence does not bypass invalid transition rollback" do
    assert_unchanged do
      update_task(expected_caller_input: @pair, **outcome.merge(state: "TASK_STATE_UNKNOWN"))
      assert_response :unprocessable_entity
    end
  end

  test "a reused Task object queries fresh evidence after its associations and old pair were read" do
    @task.events.load
    @task.messages.load
    assert_equal @pair, @task.latest_caller_input
    append_tied_input
    current = @task.latest_caller_input
    assert_equal "wire-new", current.fetch("messageId")
    assert_operator current.fetch("cursor").to_i, :>, @pair.fetch("cursor").to_i
    update_task(expected_caller_input: current, **outcome)
    assert_response :success
  end


  test "latest unbound legacy input omits and refuses even with older valid evidence and loaded associations" do
    @task.events.load
    @task.messages.load
    @task.events.create!(kind: "caller_input", payload: {})
    assert_nil @task.latest_caller_input
    get "/api/tasks/#{@task.id}", headers: headers(@recipient)
    assert_response :success
    assert_not response.parsed_body.fetch("metadata").key?("concourse.caller_input")
    assert_unchanged do
      update_task(expected_caller_input: @pair, **outcome)
      assert_stale
    end
  end

  test "latest malformed missing cross-task wrong sender or wrong role binding never falls back" do
    another = Task.open!(caller: @caller, recipient: @recipient)
    foreign = Message.record!(task: another, role: "ROLE_USER", sender: @caller, parts: [ { text: "foreign" } ])
    wrong_sender = Message.create!(task: @task, role: "ROLE_USER", sender_agent: @third, parts: [ { text: "wrong sender" } ])
    wrong_role = Message.create!(task: @task, role: "ROLE_AGENT", sender_agent: @caller, parts: [ { text: "wrong role" } ])
    [ nil, [], "bad", {}, { "message_id" => [] }, { "message_id" => "missing" },
      { "message_id" => @input.wire_message_id }, { "message_id" => foreign.message_id },
      { "message_id" => wrong_sender.message_id }, { "message_id" => wrong_role.message_id } ].each do |payload|
      @task.events.create!(kind: "caller_input", payload: payload)
      assert_nil @task.latest_caller_input
      assert_nil A2a::Serializer.task(@task).dig("metadata", "concourse.caller_input")
      assert_unchanged do
        update_task(expected_caller_input: @pair, **outcome)
        assert_stale
      end
    end
  end

  test "malformed supplied pairs are 422 with no writes and explicit null is not omission" do
    [ nil, false, [], "bad", {}, @pair.merge("extra" => "bad"), @pair.except("cursor"), @pair.except("messageId"),
      *@pair.keys.flat_map { |key| [ nil, 1, [], {}, false, "", " \t" ].map { |value| @pair.merge(key => value) } },
      *%w[0 -1 +1 01 1.0 1e2].map { |cursor| @pair.merge("cursor" => cursor) },
      @pair.merge("cursor" => "1\n") ].each do |pair|
      assert_unchanged do
        update_task(expected_caller_input: pair, **outcome)
        assert_response :unprocessable_entity
        assert_equal({ "error" => "invalid_transition" }, response.parsed_body)
      end
    end
  end

  test "valid mismatched cursor or wire ID is a content-free 409" do
    [ @pair.merge("cursor" => "99999999999999999999999999999"), @pair.merge("messageId" => @input.message_id) ].each do |pair|
      assert_unchanged do
        update_task(expected_caller_input: pair, **outcome)
        assert_stale
      end
    end
  end

  test "omission preserves ordinary behavior even on unbound legacy tasks" do
    @task.events.create!(kind: "caller_input", payload: {})
    update_task(**outcome)
    assert_response :success
    assert_equal "TASK_STATE_FAILED", @task.reload.state
  end

  # A2A §13.1: freshness refusal is not a participant or tenant discovery oracle.
  test "sender outsiders other tenants and removed participants never get freshness evidence" do
    [ @caller, @third, @outsider ].each do |agent|
      [ @pair, nil ].each do |pair|
        assert_unchanged do
          update_task(agent: agent, expected_caller_input: pair, **outcome)
          assert_response :not_found
          assert_no_evidence
        end
      end
    end
    [ @caller, @recipient ].each do |removed|
      membership = @org.memberships.find_by!(user: removed.owner)
      membership.destroy!
      assert_unchanged do
        update_task(expected_caller_input: @pair, **outcome)
        assert_includes [ 401, 403, 404 ], response.status
        assert_no_evidence
        get "/api/tasks/#{@task.id}", headers: headers(@recipient)
        assert_includes [ 401, 403, 404 ], response.status
        assert_no_evidence
      end
      @org.memberships.create!(user: removed.owner)
    end
  end

  test "held native and release one snapshots omit evidence and guarded PATCH preserves route guards" do
    %w[held native].each do |route|
      @task.update_columns(execution_route: route)
      assert_nil A2a::Serializer.task(@task.reload).dig("metadata", "concourse.caller_input")
      assert_unchanged do
        update_task(expected_caller_input: @pair, **outcome)
        assert_response :unprocessable_entity
      end
    end
    @task.update_columns(execution_route: "inbox")
    Rails.application.config.x.concourse.release_line = 1
    assert_nil A2a::Serializer.task(@task.reload).dig("metadata", "concourse.caller_input")
  end

  test "caller forged metadata cannot select task evidence" do
    spoof = { "concourse.caller_input" => { "cursor" => "99999", "messageId" => "forged" } }
    post "/a2a/#{@org.slug}/#{@recipient.qualified_handle}", params: {
      jsonrpc: "2.0", id: "fresh-send", method: "SendMessage", params: {
        message: { messageId: "forged-input", taskId: @task.id, role: "ROLE_USER", parts: [ { text: "new input" } ], metadata: spoof },
        metadata: spoof, configuration: { returnImmediately: true }
      }
    }.to_json, headers: headers(@caller).merge("A2A-Version" => "1.0")
    assert_response :success
    assert_nil response.parsed_body["error"]
    pair = @task.latest_caller_input
    assert_equal "forged-input", pair.fetch("messageId")
    assert_not_equal "99999", pair.fetch("cursor")
    assert_equal pair, response.parsed_body.dig("result", "task", "metadata", "concourse.caller_input")
    assert_empty @task.messages.find_by!(client_message_id: "forged-input").metadata
  end

  test "freshness precedes even optional delivery publication and stale requests create no envelope" do
    append_tied_input
    assert_unchanged do
      update_task(expected_caller_input: @pair, delivery: { operation: "settle", id: SecureRandom.uuid }, **outcome)
      assert_stale
    end
  end

  test "MCP matching evidence publishes its message artifact and explicit outcome atomically" do
    result = mcp_reply(expected_caller_input: @pair)
    assert_response :ok
    assert_not result.dig("result", "isError")
    assert_equal "TASK_STATE_FAILED", @task.reload.state
    assert_equal "MCP reply", @task.status_message.parts.sole.fetch("text")
    assert_equal "MCP artifact", @task.artifacts.sole.parts.sole.fetch("text")
    assert_equal @pair, result.dig("result", "structuredContent", "metadata", "concourse.caller_input")
  end

  test "MCP stale or unavailable evidence returns a content-free tool error without effects" do
    append_tied_input
    [ false, true ].each do |unavailable|
      @task.events.where(kind: "caller_input").delete_all if unavailable
      assert_unchanged do
        result = mcp_reply(expected_caller_input: @pair)
        assert_response :ok
        assert_equal true, result.dig("result", "isError")
        assert_equal({ "code" => "stale_reply", "message" => "stale_reply" }, result.dig("result", "structuredContent"))
        assert_no_evidence
      end
    end
  end

  test "MCP malformed evidence including explicit null is not omission" do
    [ nil, {}, @pair.merge("extra" => "bad"), @pair.merge("cursor" => "0"), @pair.merge("messageId" => " ") ].each do |pair|
      assert_unchanged do
        result = mcp_reply(expected_caller_input: pair)
        assert_equal true, result.dig("result", "isError")
        if (error = result.dig("result", "structuredContent"))
          assert_equal A2a::Error::CODES[:invalid_params], error.fetch("code")
        else
          assert result.dig("result", "content", 0, "text").present?
        end
      end
    end
  end

  test "MCP omission retains ordinary replies on a legacy unbound task" do
    @task.events.where(kind: "caller_input").delete_all
    result = mcp_reply
    assert_response :ok
    assert_not result.dig("result", "isError")
    assert_equal "TASK_STATE_FAILED", @task.reload.state
  end

  # A2A §13.1 still precedes freshness: a supplied pair grants no visibility.
  test "MCP supplied evidence cannot grant sender or cross-tenant recipient access" do
    [ @caller, @third, @outsider ].each do |agent|
      assert_unchanged do
        result = mcp_reply(agent: agent, expected_caller_input: @pair)
        assert_response :ok
        assert_equal true, result.dig("result", "isError")
        assert_equal A2a::Error::CODES[:task_not_found], result.dig("result", "structuredContent", "code")
        assert_no_evidence
      end
    end
  end

  private

  def mcp_reply(agent: @recipient, **freshness)
    token = "mcp-#{agent.handle}"
    stub_agent_token(token, client_id: agent.oauth_client_id, sub: agent.owner.ajent_sub, resource: :mcp, organization: agent.organization)
    post "/mcp", params: { jsonrpc: "2.0", id: "freshness", method: "tools/call",
      params: { name: "reply", arguments: { task_id: @task.id, text: "MCP reply", artifact_text: "MCP artifact",
        state: "TASK_STATE_FAILED", **freshness } } }.to_json,
      headers: headers(agent).merge("Authorization" => "Bearer #{token}", "ACCEPT" => "application/json")
    response.parsed_body
  end

  def create_agent(org, handle)
    owner = User.create!(handle: handle, ajent_sub: handle, organizations: [ org ])
    agent = Agent.create!(owner: owner, organization: org, handle: handle, oauth_client_id: "client-#{handle}")
    stub_agent_token(handle, client_id: agent.oauth_client_id, sub: owner.ajent_sub, organization: org)
    agent
  end

  def headers(agent)
    { "Authorization" => "Bearer #{agent.handle}", "CONTENT_TYPE" => "application/json", "Concourse-Organization" => agent.organization.slug }
  end

  def update_task(agent: @recipient, **payload)
    patch "/tasks/#{@task.id}", params: payload.to_json, headers: headers(agent)
  end

  def outcome
    { state: "TASK_STATE_FAILED", message: { parts: [ { text: "old failure" } ] }, artifacts: [ { parts: [ { text: "old artifact" } ] } ] }
  end

  def append_tied_input
    @task.with_lock do
      Message.create!(task: @task, role: "ROLE_USER", sender_agent: @caller,
        message_id: "00000000-0000-4000-8000-000000000000", client_message_id: "wire-new",
        created_at: @input.created_at, parts: [ { "text" => "new request" } ])
    end
  end

  def snapshot
    [ Task, Message, Artifact, TaskEvent, TaskDelivery, TaskDeliveryMessage, RelayDelivery ].map do |model|
      model.order(model.primary_key).map(&:attributes)
    end
  end

  def assert_unchanged
    before = snapshot
    jobs = enqueued_jobs.dup
    without_call(TaskDelivery, :publish!) do
      without_call(ActionCable.server, :broadcast) { yield }
    end
    assert_equal before, snapshot
    assert_equal jobs, enqueued_jobs
  end

  def without_call(object, name)
    original = object.method(name)
    refuse = ->(*) { flunk "refusal must precede #{name}" }
    object.define_singleton_method(name, refuse)
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def assert_stale
    assert_response :conflict
    assert_equal({ "error" => "stale_reply" }, response.parsed_body)
    assert_no_evidence
  end

  def assert_no_evidence
    assert_not response.body.include?("concourse.caller_input")
    assert_not response.body.include?("messageId")
    assert_not response.body.include?(@input.message_id)
    assert_not response.body.include?(@input.wire_message_id)
  end
end
