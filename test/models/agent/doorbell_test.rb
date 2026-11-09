require "test_helper"
require "async"

class Agent::DoorbellTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @organization = Organization.default
    owner = User.create!(ajent_sub: "model-door-a", handle: "model-door-a", organizations: [ @organization ])
    other = User.create!(ajent_sub: "model-door-b", handle: "model-door-b", organizations: [ @organization ])
    @caller = Agent.create!(owner: owner, handle: "caller", oauth_client_id: "model-door-client-a")
    @recipient = Agent.create!(owner: other, handle: "recipient", oauth_client_id: "model-door-client-b")
  end

  teardown { A2a::Waiters.reset! }

  test "rollback emits no hints and native or held routes emit no hints" do
    assert_no_broadcasts("agent_doorbell:#{@recipient.id}") do
      Task.transaction(requires_new: true) do
        Task.open!(recipient: @recipient, caller: @caller)
        raise ActiveRecord::Rollback
      end
      %w[native held].each do |route|
        task = Task.create!(organization: @organization, recipient_agent: @recipient, caller_agent: @caller,
          state: "TASK_STATE_SUBMITTED", execution_route: route)
        task.update!(status_at: Time.current)
        Message.create!(task: task, sender_agent: @caller, role: "ROLE_USER", parts: [ { "text" => "private" } ])
      end
    end
    assert_empty broadcasts("agent_doorbell:#{@caller.id}")
  end

  test "doorbell observation leaves the caller's association caches alone" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    assert_not task.association(:messages).loaded?
    task.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @recipient)
    assert_not task.association(:messages).loaded?
    Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "answer" } ])
    assert_not task.association(:messages).loaded?
    assert_equal 1, task.messages.count
  end

  test "a provisional inbox retired to a direct Message before commit emits no hints" do
    assert_no_broadcasts("agent_doorbell:#{@recipient.id}") do
      Task.transaction(requires_new: true) do
        task = Task.open!(recipient: @recipient, caller: @caller)
        Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "talk" } ])
        task.destroy!
      end
    end
  end

  test "removed participants cannot cause hints" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    @organization.memberships.find_by!(user: @caller.owner).remove
    assert_no_broadcasts("agent_doorbell:#{@caller.id}") do
      assert_no_broadcasts("agent_doorbell:#{@recipient.id}") do
        task.transition_to!("TASK_STATE_WORKING", by: @recipient)
      end
    end
  end

  test "the async cable callback wakes a queue in a Falcon style scheduler fiber without blocking peers" do
    frames = []
    ticks = 0
    keepalive_ticks = []
    stream = Agent::Doorbell.open(@recipient)
    # The test cable adapter inherits Async; delivery and subscribe success
    # callbacks run on its executor thread, not on this Rack body fiber.
    Async do |parent|
      ticker = parent.async do |child|
        20.times { child.sleep(0.002); ticks += 1 }
      end
      # Observe the handoff, not an 80ms host-scheduling guarantee. A bounded
      # deadline still fails a lost callback; close as soon as both facts hold.
      A2a::Exchange.with_limits(stream: 1, heartbeat: 0.02) do
        stream.each do |frame|
          frames << frame
          keepalive_ticks << ticks if frame.start_with?(": keepalive")
          if frame.start_with?("event: ready")
            Task.open!(recipient: @recipient, caller: @caller)
          end
          stream.close if frames.any? { |item| item.start_with?("event: ping") } && keepalive_ticks.any? { |count| count > 0 }
        end
      end
      ticker.wait
    end.wait
    assert frames.any? { |frame| frame.start_with?("event: ping") }
    # A busy ready callback may precede the ticker; peers must progress during a later wait.
    assert keepalive_ticks.any? { |count| count > 0 }
    assert_equal 20, ticks
    assert A2a::Waiters.acquire(@organization.id)
  end

  test "client disconnect releases the waiter and closes the body" do
    gone = Class.new(StringIO) do
      def write(*) = raise(Protocol::HTTP::RemoteError, "closed")
    end.new
    Agent::Doorbell.open(@recipient).call(gone)
    assert gone.closed?
    assert A2a::Waiters.acquire(@organization.id)
  end
end
