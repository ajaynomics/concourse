require "test_helper"
require "action_cable/subscription_adapter/inline"

class DoorbellTest < ActionDispatch::IntegrationTest
  setup do
    @organization = Organization.default
    owner = User.create!(ajent_sub: "door-a", handle: "door-a", organizations: [ @organization ])
    other = User.create!(ajent_sub: "door-b", handle: "door-b", organizations: [ @organization ])
    @caller = Agent.create!(owner: owner, handle: "caller", oauth_client_id: "door-client-a")
    @recipient = Agent.create!(owner: other, handle: "recipient", oauth_client_id: "door-client-b")
    @unrelated = Agent.create!(owner: other, handle: "unrelated", oauth_client_id: "door-client-c")
    elsewhere = Organization.create!(name: "Elsewhere", slug: "door-elsewhere")
    outsider = User.create!(ajent_sub: "door-c", handle: "door-c", organizations: [ elsewhere ])
    @outsider = Agent.create!(owner: outsider, organization: elsewhere, handle: "outsider", oauth_client_id: "door-client-d")
    @adapter = ActionCable::SubscriptionAdapter::Inline.new(ActionCable.server)
  end

  teardown { A2a::Waiters.reset! }

  test "doorbell requires app audience agent bearer authentication" do
    get "/api/doorbell"
    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], "oauth-protected-resource"
  end

  test "new inbox work rings only its recipient with no message content" do
    heard = Hash.new { |hash, key| hash[key] = [] }
    listeners = [ @caller, @recipient, @unrelated, @outsider ].to_h do |agent|
      [ agent, ->(data) { heard[agent.id] << JSON.parse(data) } ]
    end
    with_pubsub do
      listeners.each { |agent, listener| @adapter.subscribe("agent_doorbell:#{agent.id}", listener) }
      task = nil
      connect(@recipient) do
        Task.transaction do
          task = Task.open!(recipient: @recipient, caller: @caller)
          Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { text: "secret request" } ])
        end
      end
      assert_response :success
      assert_equal "text/event-stream", response.media_type
      assert_includes response.body, "event: ready\ndata:\n\n"
      assert_equal [ { "reason" => "inbox", "taskId" => task.id } ], pings.uniq
      assert_equal pings.uniq, heard[@recipient.id].uniq
      [ @caller, @unrelated, @outsider ].each { |agent| assert_empty heard[agent.id] }
      assert_not_includes response.body, "secret request"
    end
  end

  test "recipient status and message ring the sender and answered input rings the inbox again" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    with_pubsub do
      connect(@caller) do
        A2a::Exchange.new(@recipient).reply(task.id, state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => "secret reply" } ])
      end
      assert_equal [ { "reason" => "reply", "taskId" => task.id } ], pings.uniq
      assert_not_includes response.body, "secret reply"
      connect(@recipient) do
        Message.record!(task: task.reload, role: "ROLE_USER", sender: @caller, parts: [ { text: "secret answer" } ])
      end
      assert_equal [ { "reason" => "inbox", "taskId" => task.id } ], pings.uniq
    end
  end

  test "status-only and message-only replies both ring the sender" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    with_pubsub do
      connect(@caller) { A2a::Exchange.new(@recipient).reply(task.id, state: "TASK_STATE_WORKING") }
      assert_equal [ { "reason" => "reply", "taskId" => task.id } ], pings.uniq
      connect(@caller) { A2a::Exchange.new(@recipient).reply(task.id, parts: [ { "text" => "private message" } ]) }
      assert_equal [ { "reason" => "reply", "taskId" => task.id } ], pings.uniq
      assert_not_includes response.body, "private message"
    end
  end

  test "the stream suppresses valid task IDs outside the viewer scope or organization" do
    unrelated = Task.open!(recipient: @unrelated, caller: @caller)
    outside = Task.open!(recipient: @outsider, caller: @outsider)
    with_pubsub do
      connect(@recipient) do
        [ unrelated, outside ].each do |task|
          @adapter.broadcast("agent_doorbell:#{@recipient.id}", { reason: "inbox", taskId: task.id }.to_json)
        end
      end
      assert_empty pings
      assert_not_includes response.body, unrelated.id
      assert_not_includes response.body, outside.id
    end
  end

  test "queued hints are scoped again and removal ends the stream" do
    with_pubsub do
      connect(@recipient) do
        @adapter.broadcast("agent_doorbell:#{@recipient.id}", { reason: "inbox", taskId: "not-visible" }.to_json)
        @organization.memberships.find_by!(user: @recipient.owner).remove
      end
      assert_empty pings
      assert_not_includes response.body, "keepalive"
      assert A2a::Waiters.acquire(@organization.id)
    end
  end

  test "retirement ends observation before queued hints without canceling the task" do
    with_pubsub do
      task = nil
      connect(@recipient) do
        task = Task.open!(recipient: @recipient, caller: @caller)
        @recipient.retire
        @adapter.broadcast("agent_doorbell:#{@recipient.id}", { reason: "inbox", taskId: task.id }.to_json)
      end
      assert_empty pings
      assert_not_includes response.body, "keepalive"
      assert_equal "TASK_STATE_SUBMITTED", task.reload.state
      assert @caller.admitted?
      assert A2a::Waiters.acquire(@organization.id)
    end
  end

  test "quiet streams heartbeat and end at the limit" do
    with_pubsub { connect(@recipient) }
    assert_includes response.body, ": keepalive\n\n"
    assert A2a::Waiters.acquire(@organization.id)
  end

  test "test-side producer work does not consume the stream observation budget" do
    task = nil
    with_pubsub do
      connect(@recipient) do
        sleep 1.1
        task = Task.open!(recipient: @recipient, caller: @caller)
      end
      assert_equal [ { "reason" => "inbox", "taskId" => task.id } ], pings.uniq
    end
  end

  test "full cap and organization fair share return 429 before streaming" do
    A2a::Waiters.limit = 4
    assert A2a::Waiters.acquire(@organization.id)
    with_memory_cache do
      stub_agent_token("door-token", client_id: @recipient.oauth_client_id, sub: @recipient.owner.ajent_sub)
      get "/api/doorbell", headers: { "Authorization" => "Bearer door-token" }
      assert_response :too_many_requests
      assert_equal "doorbell_capacity", response.parsed_body["error"]
      assert_equal "30", response.headers["Retry-After"]
      A2a::Waiters.release(@organization.id)
      A2a::Waiters.limit = 0
      get "/api/doorbell", headers: { "Authorization" => "Bearer door-token" }
      assert_response :too_many_requests
    end
  ensure
    A2a::Waiters.limit = nil
  end

  private

  def connect(agent, &on_ready)
    original = Agent::Doorbell.method(:open)
    opener = ->(viewer) do
      stream = original.call(viewer)
      if stream
        # The synthetic producer runs in this body callback, unlike an independent real caller.
        clock = stream.method(:monotonic)
        producer_time = 0.0
        stream.define_singleton_method(:monotonic) { clock.call - producer_time }
        stream.define_singleton_method(:each) do |&emit|
          super() do |frame|
            emit.call(frame)
            close if frame.start_with?("event: ping")
            if on_ready && frame.start_with?("event: ready")
              started = clock.call
              begin
                on_ready.call
              ensure
                producer_time += clock.call - started
              end
            end
          end
        end
      end
      stream
    end
    with_memory_cache do
      stub_agent_token("door-token", client_id: agent.oauth_client_id, sub: agent.owner.ajent_sub)
      Agent::Doorbell.define_singleton_method(:open, opener)
      # End positive observations on their hint, with room for host scheduling.
      # Quiet/filtered streams still exercise a bounded limit and heartbeat.
      A2a::Exchange.with_limits(stream: 1, heartbeat: 0.02) do
        get "/api/doorbell", headers: { "Authorization" => "Bearer door-token" }
      end
    end
  ensure
    Agent::Doorbell.define_singleton_method(:open, original)
  end

  def pings
    response.body.scan(/^data: (.+)$/).map { |(data)| JSON.parse(data) }
  end

  def with_pubsub
    original = ActionCable.server.method(:pubsub)
    adapter = @adapter
    ActionCable.server.define_singleton_method(:pubsub) { adapter }
    yield
  ensure
    ActionCable.server.define_singleton_method(:pubsub, original)
  end
end
