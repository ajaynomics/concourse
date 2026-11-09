require "test_helper"

# Parent owns the base include; this test-only integration seam exercises the
# concern before that checkpoint without editing RelayTask's base file.
RelayTask.include RelayTask::NativeEvents unless RelayTask < RelayTask::NativeEvents

class RelayTaskNativeEventsTest < ActiveSupport::TestCase
  setup do
    @organization = Organization.default
    a = User.create!(ajent_sub: "stream-a", handle: "sa", email: "sa@example.com", organizations: [ @organization ])
    b = User.create!(ajent_sub: "stream-b", handle: "sb", email: "sb@example.com", organizations: [ @organization ])
    @caller = Agent.create!(owner: a, handle: "a", oauth_client_id: "stream-a")
    @recipient = Agent.create!(owner: b, handle: "b", oauth_client_id: "stream-b")
    @task = Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      execution_route: "native", context_id: "public-context", state: "TASK_STATE_SUBMITTED", status_at: Time.current)
    @relay = RelayTask.create!(task: @task, organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      endpoint_url: "https://native.example.test/a2a", resource: "https://native.example.test/a2a", generation: 1,
      native_task_id: "native-task", native_context_id: "native-context", native_streaming: true)
    @relay.acquire_observation!(holder: "reader")
    @fence = @relay.fence
  end

  test "equal append chunks and empty final append are immutable ordered events not deduplicated" do
    # A2A §4.2.2: equal chunks are distinct occurrences, including lastChunk.
    observe("task" => snapshot)
    delta = { "artifactId" => "wire", "parts" => [ { "text" => "same", "metadata" => { "part" => 1 } } ],
      "name" => "name", "description" => "desc", "metadata" => { "artifact" => true }, "extensions" => [ "urn:test" ] }
    observe("artifactUpdate" => ids.merge("artifact" => delta, "append" => false, "lastChunk" => false, "metadata" => { "event" => 1 }))
    twice = ids.merge("artifact" => delta.slice("artifactId", "parts"), "append" => true, "lastChunk" => false)
    2.times { observe("artifactUpdate" => twice) }
    observe("artifactUpdate" => ids.merge("artifact" => { "artifactId" => "wire", "parts" => [] }, "append" => true, "lastChunk" => true))
    events = @task.events.where(kind: "artifact").order(:id).to_a
    assert_equal 4, events.size
    assert_equal [ "same", "same", "same" ], @task.artifacts.sole.parts.map { |part| part["text"] }
    assert_equal [], events.last.payload.dig("artifact", "parts")
    assert events.last.payload["lastChunk"]
    assert_equal "public-context", events.first.payload["contextId"]
    assert_equal({ "event" => 1 }, events.first.payload["metadata"])
    assert_equal "name", @task.artifacts.sole.name
    assert_equal "desc", @task.artifacts.sole.description
    assert_equal [ "urn:test" ], @task.artifacts.sole.extensions
    assert_not events.first.update(payload: {})
    assert_equal "same", events.first.reload.payload.dig("artifact", "parts", 0, "text")
  end

  test "snapshot and reconnect use boundaries never invented native status events and preserve terminal artifacts" do
    observe("task" => snapshot)
    assert_equal 0, @task.events.where(kind: "status").count
    assert @relay.reload.gap
    mark = @task.reload.status_at
    count = @task.events.count
    travel 10.seconds do
      observe("task" => snapshot)
      assert_equal mark, @task.reload.status_at
      assert_equal count, @task.events.count
    end
    terminal = snapshot.merge("status" => { "state" => "TASK_STATE_COMPLETED" },
      "artifacts" => [ { "artifactId" => "final", "parts" => [ { "data" => { "result" => 7 } } ] } ])
    observe("task" => terminal)
    assert_equal "TASK_STATE_COMPLETED", @task.reload.state
    assert_equal "final", @task.artifacts.sole.native_artifact_id
    assert_equal "snapshot_boundary", @task.events.order(:id).last.kind
    assert_equal 0, @task.events.where(kind: "status").count
  end

  test "native statuses preserve upstream timestamp separately and event metadata" do
    observe("task" => snapshot)
    upstream = "2026-10-07T10:00:00Z"
    observe("statusUpdate" => ids.merge("status" => { "state" => "TASK_STATE_INPUT_REQUIRED", "timestamp" => upstream }, "metadata" => { "native" => true }))
    event = @task.events.where(kind: "status").sole
    assert_equal upstream, event.upstream_timestamp
    assert_equal({ "native" => true }, event.payload["metadata"])
    assert_not_equal upstream, event.payload.dig("status", "timestamp")
    assert_equal @task.id, event.payload["taskId"]
  end

  test "strict raw oneof task context artifact boolean message and scoped references fail atomically" do
    malformed = [ {}, { "task" => snapshot, "message" => {} }, { "payload" => { "$case" => "task", "value" => snapshot } },
      { "task" => snapshot.merge("id" => "foreign") }, { "task" => snapshot.merge("contextId" => "foreign") },
      { "statusUpdate" => ids.merge("taskId" => "foreign", "status" => { "state" => "TASK_STATE_COMPLETED" }) },
      { "artifactUpdate" => ids.merge("artifact" => { "artifactId" => "a", "parts" => [] }, "append" => "true") },
      { "artifactUpdate" => ids.merge("artifact" => { "artifactId" => "a", "parts" => [ { "text" => "x" } ] }, "append" => true) },
      { "message" => { "messageId" => "m", "role" => "ROLE_AGENT", "contextId" => "foreign", "parts" => [ { "text" => "x" } ] } },
      { "message" => { "messageId" => "m", "role" => "ROLE_AGENT", "contextId" => "native-context", "parts" => [ { "text" => "x" } ], "referenceTaskIds" => [ "foreign" ] } } ]
    malformed.each { |payload| assert_raises(RelayTask::InvalidSnapshot) { observe(payload) } }
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
    assert_empty @task.events
    assert_empty @task.artifacts
    assert_empty @task.messages
  end

  test "fence invalidation and participant removal reject late events" do
    @relay.with_lock { @relay.invalidate_observation! }
    assert_raises(RelayTask::LostLease) { observe("task" => snapshot) }
    @relay.acquire_observation!(holder: "reader")
    @fence = @relay.fence
    @organization.memberships.find_by!(user: @caller.owner).remove
    assert_raises(Agent::Unadmitted) { observe("task" => snapshot) }
    assert_empty @task.events
  end

  test "retained budget exhaustion rolls back the assembled artifact and event together" do
    @relay.define_singleton_method(:check_retained_budget!) { raise RelayTask::InvalidSnapshot }
    assert_raises(RelayTask::InvalidSnapshot) do
      observe("artifactUpdate" => ids.merge("artifact" => { "artifactId" => "wire", "parts" => [ { "text" => "x" } ] }))
    end
    assert_empty @task.artifacts
    assert_empty @task.events
  end

  private

  def ids
    { "taskId" => "native-task", "contextId" => "native-context" }
  end

  def snapshot
    { "id" => "native-task", "contextId" => "native-context", "status" => { "state" => "TASK_STATE_WORKING" } }
  end

  def observe(payload)
    @relay.observe_native_event!(payload: payload, holder: "reader", fence: @fence)
  end
end
