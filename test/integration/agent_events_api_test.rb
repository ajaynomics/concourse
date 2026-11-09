require "test_helper"

class AgentEventsApiTest < ActionDispatch::IntegrationTest
  setup do
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @organization = Organization.create!(name: "Events API", slug: "events-api")
    @caller = create_agent("sender")
    @recipient = create_agent("receiver")
    @bystander = create_agent("bystander")
    @elsewhere = Organization.create!(name: "Elsewhere", slug: "events-elsewhere")
    @outsider = create_agent("outsider", organization: @elsewhere)
    @outsider_peer = create_agent("outsider-peer", organization: @elsewhere)
    @task = Task.open!(caller: @caller, recipient: @recipient)
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @previous_line
    A2a::Waiters.limit = nil
    A2a::Waiters.reset!
  end

  # -- authentication and visibility ------------------------------------

  test "every events route needs an app-audience agent bearer" do
    get api_events_path
    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], "oauth-protected-resource"
    put api_events_cursor_path, params: { cursor: 0 }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized
    get api_me_path
    assert_response :unauthorized

    stub_agent_token("wrong-audience", client_id: "client-receiver", sub: "events-receiver", resource: :mcp)
    get api_events_path, headers: { "Authorization" => "Bearer wrong-audience" }
    assert_response :unauthorized
    put api_events_cursor_path, params: { cursor: 0 }.to_json,
      headers: { "Authorization" => "Bearer wrong-audience", "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized
  end

  test "a token from someone who is not a member is 403 not_a_member" do
    stub_agent_token("stranger", client_id: "stranger-client", sub: "stranger", organization: nil)
    get api_events_path, headers: { "Authorization" => "Bearer stranger" }

    assert_response :forbidden
    assert_equal "not_a_member", response.parsed_body["error"]
  end

  test "an agent reads only events addressed to it, never another organization's or another agent's" do
    request("for the receiver")
    outside = Task.open!(caller: @outsider, recipient: @outsider_peer)
    Message.record!(task: outside, role: "ROLE_USER", sender: @outsider, parts: [ { "text" => "other tenant" } ])

    events(@recipient)
    assert_equal [ @task.id ], response.parsed_body["events"].pluck("task_id")
    [ @bystander, @caller, @outsider ].each do |agent|
      events(agent)
      assert_empty response.parsed_body["events"], agent.handle
    end
    events(@outsider_peer)
    assert_equal [ outside.id ], response.parsed_body["events"].pluck("task_id")
    assert_not_includes response.body, "for the receiver"
  end

  test "removing the sender takes its tasks out of reach" do
    request("before leaving")
    @organization.memberships.find_by!(user: @caller.owner).remove

    events(@recipient)
    assert_empty response.parsed_body["events"]
  end

  # -- reading -----------------------------------------------------------

  test "events come back in order with a cursor and no more" do
    request("first")
    reply(state: "TASK_STATE_WORKING", parts: [ { "text" => "second" } ])
    request("third")

    events(@recipient)
    assert_response :success
    assert_equal "application/json", response.media_type
    body = response.parsed_body
    assert_equal [ 1, 2 ], body["events"].pluck("id")
    assert_equal [ 2, false, 1 ], [ body["cursor"], body["more"], body["oldest"] ]
    assert_equal %w[message message], body["events"].pluck("type")

    events(@caller)
    assert_equal %w[message state], response.parsed_body["events"].pluck("type")
  end

  test "after and limit page through the log" do
    5.times { |index| request("message #{index}") }

    events(@recipient, after: 1, limit: 2)
    body = response.parsed_body
    assert_equal [ 2, 3 ], body["events"].pluck("id")
    assert_equal [ 3, true ], [ body["cursor"], body["more"] ]
    events(@recipient, after: 3, limit: 100)
    assert_equal [ 4, 5 ], response.parsed_body["events"].pluck("id")
    events(@recipient, after: 5)
    assert_equal [ [], 5, false ], response.parsed_body.values_at("events", "cursor", "more")
  end

  test "reading is at least once until the client acknowledges" do
    2.times { request("n") }

    2.times do
      events(@recipient)
      assert_equal [ 1, 2 ], response.parsed_body["events"].pluck("id")
    end
    ack(@recipient, 1)
    assert_response :no_content
    events(@recipient)
    assert_equal [ 2 ], response.parsed_body["events"].pluck("id"), "omitted after resumes at the server cursor"
    events(@recipient, after: 0)
    assert_equal [ 1, 2 ], response.parsed_body["events"].pluck("id"), "an explicit after wins"
  end

  test "the cursor endpoint is cumulative, monotonic and idempotent" do
    3.times { request("n") }

    ack(@recipient, 2)
    assert_response :no_content
    assert_empty response.body
    assert_equal 2, @recipient.reload.event_cursor
    ack(@recipient, 2)
    assert_response :no_content
    ack(@recipient, 1)
    assert_response :no_content
    assert_equal 2, @recipient.reload.event_cursor
    ack(@recipient, "3")
    assert_response :no_content
    assert_equal 3, @recipient.reload.event_cursor
  end

  test "a bad or future cursor is 400 cursor_invalid" do
    request("one")

    [ "abc", "-1", "1.5", "", "99999999999999999999" ].each do |value|
      events(@recipient, after: value)
      assert_response :bad_request, value
      assert_equal({ "error" => "cursor_invalid" }, response.parsed_body)
    end
    events(@recipient, after: 2)
    assert_response :bad_request
    [ -1, 2, "x", nil, 1.5, [ 1 ], { "a" => 1 } ].each do |value|
      ack(@recipient, value)
      assert_response :bad_request, value.inspect
      assert_equal "cursor_invalid", response.parsed_body["error"]
    end
    assert_equal 0, @recipient.reload.event_cursor
  end

  test "a cursor behind purged events is 410 cursor_expired with the oldest kept" do
    old = Task.open!(caller: @caller, recipient: @recipient)
    2.times { Message.record!(task: old, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "old" } ]) }
    request("kept")
    old.update_columns(updated_at: 31.days.ago)
    PurgeExpiredTasksJob.perform_now

    events(@recipient, after: 1)
    assert_response :gone
    assert_equal({ "error" => "cursor_expired", "oldest" => 3 }, response.parsed_body)
    get api_events_path, headers: { **headers(@recipient), "Accept" => "text/event-stream", "Last-Event-ID" => "1" }
    assert_response :gone
    events(@recipient, after: 2)
    assert_response :success
    assert_equal [ 3 ], response.parsed_body["events"].pluck("id")
    events(@recipient, after: 0)
    assert_equal [ 3 ], response.parsed_body["events"].pluck("id")
    assert_equal 3, response.parsed_body["oldest"], "a client at cursor 0 can see the purge in every response"
    events(@recipient)
    assert_response :success
    assert_equal [ 3, 3 ], [ response.parsed_body["events"].pluck("id").first, response.parsed_body["oldest"] ], "omitted after, server cursor 0"
    events(@recipient, after: 3)
    assert_equal [ [], 3 ], response.parsed_body.values_at("events", "oldest")
  end

  test "bad limit and wait are 422 invalid_params" do
    [ { limit: "0" }, { limit: "101" }, { limit: "x" }, { wait: "26" }, { wait: "-1" }, { wait: "1.5" } ].each do |params|
      events(@recipient, **params)
      assert_response :unprocessable_entity, params.inspect
      assert_equal "invalid_params", response.parsed_body["error"]
    end
  end

  test "a long poll returns at once when events exist and an empty page when the wait ends" do
    request("waiting")
    started = monotonic
    A2a::Exchange.with_limits(poll: 0.01) { events(@recipient, wait: 5) }
    assert_operator monotonic - started, :<, 1
    assert_equal [ 1 ], response.parsed_body["events"].pluck("id")

    started = monotonic
    A2a::Exchange.with_limits(poll: 0.01) { events(@recipient, after: 1, wait: 1) }
    assert_operator monotonic - started, :>=, 0.9
    assert_equal [ [], 1, false ], response.parsed_body.values_at("events", "cursor", "more")
    assert A2a::Waiters.acquire(@organization.id), "the slot is released after the wait"
  end

  test "a long poll wakes for an event written while it waits" do
    original = A2a::Waiters.method(:idle)
    produced = false
    producer = -> { request("while you waited") }
    A2a::Waiters.define_singleton_method(:idle) do |_seconds|
      unless produced
        produced = true
        producer.call
      end
      original.call(0)
    end

    events(@recipient, wait: 5)
    assert_equal [ 1 ], response.parsed_body["events"].pluck("id")
  ensure
    A2a::Waiters.define_singleton_method(:idle, original)
  end

  test "a long poll with no free slot is 429 with Retry-After, but an immediate read still works" do
    A2a::Waiters.limit = 0

    capture_events("concourse.a2a.waiter_cap") do |logged|
      events(@recipient, wait: 1)
      assert_equal [ { kind: "events", limit: 0 } ], logged.map { |event| event[:payload] }
    end
    assert_response :too_many_requests
    assert_equal "stream_capacity", response.parsed_body["error"]
    assert_equal AgentEvent::RETRY_AFTER, response.headers["Retry-After"]
    events(@recipient)
    assert_response :success
  end

  test "an organization cannot take more than its fair share of waiting slots" do
    A2a::Waiters.limit = 4
    assert A2a::Waiters.acquire(@organization.id)

    events(@recipient, wait: 1)
    assert_response :too_many_requests
    events(@outsider, wait: 0)
    assert_response :success
  end

  # -- payload size ------------------------------------------------------

  test "a page stays under one mebibyte and the rest follows" do
    text = "x" * 60.kilobytes
    20.times { request(text) }

    events(@recipient)
    assert_operator response.body.bytesize, :<=, AgentEvent::PAGE_BYTES + 1.kilobyte
    first = response.parsed_body
    assert first["more"]
    events(@recipient, after: first["cursor"])
    assert_equal 20, first["events"].size + response.parsed_body["events"].size
  end

  test "parts over 64 KiB arrive truncated without parts" do
    request("p" * (AgentEvent::PARTS_BYTES + 1))

    events(@recipient)
    event = response.parsed_body["events"].sole
    assert event["truncated"]
    assert_not event["message"].key?("parts")
    assert_not_includes response.body, "pppp"
  end

  # -- server-sent events ------------------------------------------------

  test "the stream frames ready, events with ids, keepalives and bye" do
    request("first")
    reply(state: "TASK_STATE_WORKING")
    request("second")

    frames = stream(@recipient, after: 0)

    assert_response :success
    assert_equal "text/event-stream", response.media_type
    assert_equal "no-cache", response.headers["Cache-Control"]
    assert_equal "ready", frames.first[:event]
    assert_equal({ "cursor" => 0, "oldest" => 1 }, frames.first[:data])
    assert_nil frames.first[:id]
    delivered = frames.select { |frame| frame[:id] }
    assert_equal [ "1", "2" ], delivered.pluck(:id)
    assert_equal %w[message message], delivered.pluck(:event)
    assert_equal delivered.pluck(:id).map(&:to_i), delivered.map { |frame| frame[:data]["id"] }
    assert_equal "bye", frames.last[:event]
    assert_includes response.body, ": keepalive\n\n"
  end

  test "Last-Event-ID resumes after the id and beats the after parameter" do
    3.times { request("n") }

    frames = stream(@recipient, after: 0, last_event_id: "2")
    assert_equal({ "cursor" => 2, "oldest" => 1 }, frames.first[:data])
    assert_equal [ "3" ], frames.filter_map { |frame| frame[:id] }
  end

  test "the stream starts at the server cursor when nothing else is given" do
    3.times { request("n") }
    ack(@recipient, 1)

    frames = stream(@recipient)
    assert_equal [ "2", "3" ], frames.filter_map { |frame| frame[:id] }
  end

  test "the stream delivers events written after it opens and only its agent's" do
    frames = stream(@recipient, after: 0, on_ready: -> {
      request("live")
      other = Task.open!(caller: @caller, recipient: @bystander)
      Message.record!(task: other, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "not yours" } ])
    })

    live = frames.select { |frame| frame[:id] }
    assert_equal [ "1" ], live.pluck(:id)
    assert_equal "live", live.sole[:data].dig("message", "parts", 0, "text")
    assert_not_includes response.body, "not yours"
  end

  test "the stream never sends an agent its own actions" do
    request("mine")
    frames = stream(@caller, after: 0)

    assert_empty frames.filter_map { |frame| frame[:id] }
  end

  test "the stream rejects a bad or expired cursor before it starts" do
    request("one")
    get api_events_path, headers: { **headers(@recipient), "Accept" => "text/event-stream", "Last-Event-ID" => "banana" }
    assert_response :bad_request
    assert_equal "application/json", response.media_type
    get api_events_path, headers: { **headers(@recipient), "Accept" => "text/event-stream", "Last-Event-ID" => "9" }
    assert_response :bad_request
  end

  test "a full cap is 429 before the stream starts and an open stream holds a slot" do
    A2a::Waiters.limit = 4
    assert A2a::Waiters.acquire(@organization.id)

    request("never in telemetry")
    capture_events("concourse.a2a.waiter_cap") do |logged|
      get api_events_path, headers: { **headers(@recipient), "Accept" => "text/event-stream" }
      assert_equal [ { kind: "events_stream", limit: 4 } ], logged.map { |event| event[:payload] }
      assert_not_includes logged.inspect, "never in telemetry"
    end
    assert_response :too_many_requests
    assert_equal "stream_capacity", response.parsed_body["error"]
    assert_equal AgentEvent::RETRY_AFTER, response.headers["Retry-After"]
    assert_equal "application/json", response.media_type
    A2a::Waiters.release(@organization.id)

    stream(@recipient, after: 0)
    assert_response :success
    assert A2a::Waiters.acquire(@organization.id), "the stream released its slot"
  end

  test "removal ends an open stream without another event" do
    frames = stream(@recipient, after: 0, on_ready: -> {
      request("sent before removal")
      @organization.memberships.find_by!(user: @recipient.owner).remove
    })

    assert_equal [ "ready" ], frames.pluck(:event)
    assert_not_includes response.body, "sent before removal"
    assert_not_includes response.body, "bye"
  end

  # -- identity ----------------------------------------------------------

  test "me is the identity plus only the capabilities this server implements" do
    get api_identity_path, headers: headers(@recipient)
    identity = response.parsed_body
    get api_me_path, headers: headers(@recipient)

    assert_response :success
    body = response.parsed_body
    assert_equal identity, body.except("capabilities", "limits")
    assert_equal %w[events events.sse], body["capabilities"]
    assert_equal({ "page_max" => 100, "page_bytes" => 1.megabyte, "part_bytes" => 64.kilobytes, "wait_max" => 25,
                   "stream_seconds" => 900, "heartbeat_seconds" => 15 }, body.dig("limits", "events"))
    assert_not_includes body["capabilities"], "reply.idempotent"
  end

  test "identity is unchanged" do
    get api_identity_path, headers: headers(@recipient)

    assert_response :success
    assert_equal %w[agent_id handle network_agent oauth_client_id organization owner owner_id prefix release_line],
      response.parsed_body.keys.sort
  end

  test "release line 1 neither serves nor advertises events" do
    Rails.application.config.x.concourse.release_line = 1

    get api_events_path, headers: headers(@recipient)
    assert_response :not_found
    ack(@recipient, 0)
    assert_response :not_found
    get api_me_path, headers: headers(@recipient)
    assert_response :success
    assert_equal [], response.parsed_body["capabilities"]
    assert_equal({}, response.parsed_body["limits"])
    get api_identity_path, headers: headers(@recipient)
    assert_not response.parsed_body.key?("release_line")
  end

  # -- v3 surfaces keep working -----------------------------------------

  test "the inbox, next_task and doorbell are unchanged by the log" do
    request("existing path")

    get "/agents/#{@recipient.id}/tasks", headers: headers(@recipient)
    assert_response :success
    assert_equal [ @task.id ], response.parsed_body["tasks"].pluck("id")
    get api_next_task_path, headers: headers(@recipient)
    assert_response :success
    assert_equal @task.id, response.parsed_body.dig("task", "id")
    patch worker_task_path(@task), params: { state: "TASK_STATE_COMPLETED", message: { parts: [ { text: "done" } ] } }.to_json,
      headers: headers(@recipient)
    assert_response :success
    get api_task_path(@task), headers: headers(@caller)
    assert_equal "TASK_STATE_COMPLETED", response.parsed_body.dig("status", "state")

    events(@caller)
    assert_equal %w[message state], response.parsed_body["events"].pluck("type")
    assert_equal "TASK_STATE_COMPLETED", response.parsed_body["events"].last["state"]
  end

  test "an A2A send is one event for the recipient and none for the sender" do
    stub_agent_token("a2a-sender", client_id: @caller.oauth_client_id, sub: @caller.owner.ajent_sub, organization: @organization)
    rpc(owner: @recipient.prefix, agent: @recipient.handle, method: "SendMessage", token: "a2a-sender", organization: @organization,
      params: { message: { messageId: "wire-1", role: "ROLE_USER", parts: [ { text: "over A2A" } ] }, configuration: { returnImmediately: true } })

    events(@recipient)
    event = response.parsed_body["events"].sole
    assert_equal "wire-1", event.dig("message", "messageId")
    assert_equal [ { "text" => "over A2A" } ], event.dig("message", "parts")
    events(@caller)
    assert_empty response.parsed_body["events"]
  end

  private

  def create_agent(handle, organization: @organization)
    owner = User.create!(handle: handle, ajent_sub: "events-#{handle}", organizations: [ organization ])
    agent = Agent.create!(owner: owner, organization: organization, handle: handle, oauth_client_id: "client-#{handle}")
    stub_agent_token(handle, client_id: agent.oauth_client_id, sub: owner.ajent_sub, organization: organization)
    agent
  end

  def headers(agent)
    { "Authorization" => "Bearer #{agent.handle}", "CONTENT_TYPE" => "application/json" }
  end

  def request(text)
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => text } ])
  end

  def reply(state: nil, parts: nil)
    A2a::Exchange.reply(agent: @recipient, task_id: @task.id, state: state, parts: parts)
  end

  def events(agent, **query)
    get api_events_path, params: query, headers: headers(agent)
  end

  def ack(agent, cursor)
    put api_events_cursor_path, params: { cursor: cursor }.to_json, headers: headers(agent)
  end

  # Opens the stream, which ends at its own short limit, and returns its frames.
  def stream(agent, after: nil, last_event_id: nil, on_ready: nil)
    original = AgentEvent::Stream.method(:open)
    opener = ->(viewer, **options) do
      body = original.call(viewer, **options)
      if body && on_ready
        body.define_singleton_method(:each) do |&emit|
          super() do |frame|
            emit.call(frame)
            on_ready.call if frame.start_with?("event: ready")
          end
        end
      end
      body
    end
    AgentEvent::Stream.define_singleton_method(:open, opener)
    request_headers = headers(agent).merge("Accept" => "text/event-stream")
    request_headers["Last-Event-ID"] = last_event_id if last_event_id
    A2a::Exchange.with_limits(stream: 0.3, heartbeat: 0.05, poll: 0.02) do
      get api_events_path, params: ({ after: after } if after), headers: request_headers
    end
    parse_frames(response.body)
  ensure
    AgentEvent::Stream.define_singleton_method(:open, original)
  end

  def parse_frames(body)
    body.split("\n\n").filter_map do |chunk|
      lines = chunk.lines.map(&:chomp).reject { |line| line.start_with?(":") }
      next if lines.empty?

      fields = lines.to_h { |line| line.split(": ", 2) }
      { id: fields["id"], event: fields["event"], data: JSON.parse(fields.fetch("data")) }
    end
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
