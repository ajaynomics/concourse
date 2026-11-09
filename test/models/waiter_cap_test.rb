require "test_helper"

class WaiterCapTest < ActiveSupport::TestCase
  setup do
    owner = User.create!(ajent_sub: "1", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    other = User.create!(ajent_sub: "2", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    @caller = Agent.create!(owner: owner, handle: "codex", oauth_client_id: "client-a")
    @recipient = Agent.create!(owner: other, handle: "pi", oauth_client_id: "client-b")
    A2a::Waiters.limit = 1
    A2a::Waiters.reset!
  end

  teardown do
    A2a::Waiters.limit = nil
    A2a::Waiters.reset!
  end

  test "a full cap returns at once and logs no content" do
    secret = "waiter-secret-#{SecureRandom.hex(8)}"
    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      assert A2a::Waiters.acquire
      held << true
      release.pop
    ensure
      A2a::Waiters.release
    end
    held.pop

    capture_events("concourse.a2a.waiter_cap") do |events|
      A2a::Exchange.with_limits(inbox: 30, blocking: 30, poll: 0.05) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_nil A2a::Exchange.next_task(@recipient)
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5

        task = Task.open!(recipient: @recipient, caller: @caller)
        Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => secret } ])
        error = assert_raises(A2a::RelayError) do
          A2a::Exchange.send_message(
            caller: @caller,
            recipient: @recipient,
            message: {
              "role" => "ROLE_USER",
              "parts" => [ { "text" => secret } ],
              "messageId" => "cap-1",
              "taskId" => task.id
            },
            configuration: {}
          )
        end
        assert_equal "RELAY_WAIT_LIMIT", error.data.sole.fetch("reason")
        assert_equal task.id, error.data.sole.dig("metadata", "taskId")
        assert_not_includes error.to_h.to_json, secret
        assert_equal "TASK_STATE_SUBMITTED", task.reload.state
        assert task.actionable?
        assert_equal 1, Task.count
        assert_equal 2, task.messages.count
        assert_equal "accepted", RelayDelivery.sole.phase
      end

      assert_equal %w[next_task send_message], events.map { |event| event.dig(:payload, :kind) }
      assert events.none? { |event| event.inspect.include?(secret) }
    end
  ensure
    release << true
    holder.join
  end

  test "an unanswered input-required task is not the next task" do
    asked = Task.open!(recipient: @recipient, caller: @caller)
    Message.record!(task: asked, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "a" } ])
    asked.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @recipient)

    A2a::Exchange.with_limits(inbox: 0) do
      assert_nil A2a::Exchange.next_task(@recipient)
    end

    Message.record!(task: asked, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "b" } ])
    A2a::Exchange.with_limits(inbox: 0) do
      assert_equal asked, A2a::Exchange.next_task(@recipient)
    end
  end

  test "no organization holds more than its share of the waiting slots" do
    A2a::Waiters.limit = 8

    2.times { assert A2a::Waiters.acquire(1) }
    assert_not A2a::Waiters.acquire(1), "a quarter of 8 is 2"
    assert A2a::Waiters.acquire(2), "another organization still gets in"

    A2a::Waiters.release(1)
    assert A2a::Waiters.acquire(1)
  end
end
