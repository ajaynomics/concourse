require "test_helper"

class A2a::StreamTest < ActiveSupport::TestCase
  setup do
    owner = User.create!(ajent_sub: "1", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    other = User.create!(ajent_sub: "2", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    @caller = Agent.create!(owner: owner, handle: "codex", oauth_client_id: "client-a")
    @recipient = Agent.create!(owner: other, handle: "pi", oauth_client_id: "client-b")
    @task = Task.open!(recipient: @recipient, caller: @caller)
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "build it" } ])
  end

  teardown { A2a::Waiters.reset! }

  test "every new status and artifact is an event, in the order it happened" do
    reply(state: "TASK_STATE_WORKING")
    reply(artifact: { parts: [ { "text" => "done" } ] }, state: "TASK_STATE_COMPLETED")

    assert_equal [ [ "TASK_STATE_SUBMITTED", false ], [ "TASK_STATE_WORKING", false ], [ nil, true ], [ "TASK_STATE_COMPLETED", false ] ],
      @task.events.order(:id).map { |event| [ event.state, event.artifact? ] }
  end

  test "the task comes first, then the events after it, and the stream ends at a terminal state" do
    stream = A2a::Stream.task(@task)
    reply(state: "TASK_STATE_WORKING")
    reply(artifact: { name: "result", parts: [ { "text" => "done" } ] }, state: "TASK_STATE_COMPLETED")

    events = collect(stream)

    assert_equal "TASK_STATE_SUBMITTED", events.first.dig("task", "status", "state")
    assert_equal [ "TASK_STATE_WORKING", "TASK_STATE_COMPLETED" ], events.filter_map { |event| event.dig("statusUpdate", "status", "state") }
    artifact = events.third.fetch("artifactUpdate")
    assert_equal({ "taskId" => @task.id, "contextId" => @task.context_id }, artifact.slice("taskId", "contextId"))
    assert_equal "result", artifact.dig("artifact", "name")
    assert artifact["lastChunk"]
    assert_equal 4, events.size
  end

  test "two streams on one task send the same events" do
    first = A2a::Stream.task(@task)
    second = A2a::Stream.task(@task)
    reply(state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => "which branch?" } ])
    reply_from_caller_then(state: "TASK_STATE_COMPLETED")

    assert_equal collect(first), collect(second)
    assert_equal "which branch?", collect(A2a::Stream.task(@task)).first.dig("task", "status", "message", "parts", 0, "text")
  end

  test "a quiet stream sends heartbeats, ends at the stream limit, and frees its waiter" do
    events = collect(A2a::Stream.task(@task), heartbeat: 0.03, stream: 0.12)

    assert events.first.key?("task")
    assert_includes events, nil
    assert A2a::Waiters.acquire
  end

  test "a full waiter cap sends the task and ends" do
    A2a::Waiters.limit = 0
    reply(state: "TASK_STATE_WORKING")

    capture_events("concourse.a2a.waiter_cap") do |logged|
      assert_equal 1, collect(A2a::Stream.task(@task)).size
      assert_equal "stream", logged.sole.dig(:payload, :kind)
    end
  ensure
    A2a::Waiters.limit = nil
  end

  test "a terminal task is the whole stream" do
    reply(state: "TASK_STATE_COMPLETED")

    assert_equal [ "TASK_STATE_COMPLETED" ], collect(A2a::Stream.task(@task)).map { |event| event.dig("task", "status", "state") }
  end

  test "a client that leaves mid-stream is not an error, and the stream lets go of its waiter and connection" do
    gone = Class.new(StringIO) do
      def write(*) = raise(Protocol::HTTP::RemoteError, "Remote connection closed during flush")
    end.new
    stream = A2a::Stream.task(@task)

    assert_no_error_reported do
      A2a::Exchange.with_limits(poll: 0.01, heartbeat: 0.01, stream: 1) do
        A2a::Rpc::EventStream.new(id: 1, stream: stream).call(gone)
      end
    end
    assert gone.closed?
  end

  test "an error inside the stream is reported once, and the stream still closes" do
    io = StringIO.new
    broken = Object.new.tap { |stream| def stream.each = raise("boom") }

    assert_error_reported(RuntimeError) { A2a::Rpc::EventStream.new(id: 1, stream: broken).call(io) }
    assert_includes io.string, %("code":-32603)
    assert io.closed?
  end

  test "either participant removal stops a stream before queued events even for an admitted viewer" do
    stream = A2a::Stream.task(@task, viewer: @caller)
    reply(state: "TASK_STATE_WORKING")
    events = []
    A2a::Exchange.with_limits(poll: 0.01, stream: 0.1) do
      stream.each do |event|
        events << event
        @task.organization.memberships.find_by!(user: @recipient.owner).remove
      end
    end
    assert_equal 1, events.size
    assert @caller.admitted?
    assert_not @recipient.admitted?
    assert_equal "TASK_STATE_WORKING", @task.reload.state
  end

  test "removal before HTTP stream consumption exposes no initial cached task" do
    stream = A2a::Stream.task(@task, viewer: @caller)
    @task.organization.memberships.find_by!(user: @recipient.owner).remove
    assert_empty collect(stream)
  end

  test "a cached admission result cannot hide another connection's participant removal" do
    stream = A2a::Stream.task(@task, viewer: @caller)
    reply(state: "TASK_STATE_WORKING")
    membership_id = @task.organization.memberships.find_by!(user: @recipient.owner).id
    events = []
    ActiveRecord::Base.cache do
      A2a::Exchange.with_limits(poll: 0.01, stream: 0.1) do
        stream.each do |event|
          events << event
          # Raw SQL simulates another process without clearing this request's
          # query cache. A2A §13.1 requires fresh admission before disclosure.
          if events.one?
            ActiveRecord::Base.connection.raw_connection.execute("DELETE FROM memberships WHERE id = #{membership_id}")
          end
        end
      end
    end
    assert_equal 1, events.size
    assert_not @recipient.admitted?
  end

  test "a cached direct Message admission cannot hide participant removal before consumption" do
    answer = A2a::DirectMessage.new(payload: { "messageId" => "direct", "contextId" => "context",
      "role" => "ROLE_AGENT", "parts" => [ { "text" => "private synthetic" } ] })
    stream = A2a::Stream.message(answer, viewer: @caller, recipient: @recipient)
    membership_id = @task.organization.memberships.find_by!(user: @recipient.owner).id
    ActiveRecord::Base.cache do
      assert stream.send(:accessible?)
      ActiveRecord::Base.connection.raw_connection.execute("DELETE FROM memberships WHERE id = #{membership_id}")
      assert_empty collect(stream)
    end
  end

  private

  def reply(**changes)
    A2a::Exchange.new(@recipient).reply(@task.id, **changes)
  end

  def reply_from_caller_then(state:)
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "main" } ])
    reply(state: state)
  end

  def collect(stream, **limits)
    A2a::Exchange.with_limits(poll: 0.01, stream: 1, **limits) do
      events = []
      stream.each { |event| events << event }
      events
    end
  end
end
