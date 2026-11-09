require "test_helper"

class NativeRelayStreamingTest < ActiveSupport::TestCase
  setup do
    organization = Organization.default
    owner = User.create!(ajent_sub: "stream-a", handle: "caller", email: "caller@example.com", organizations: [ organization ])
    other = User.create!(ajent_sub: "stream-b", handle: "recipient", email: "recipient@example.com", organizations: [ organization ])
    @caller = Agent.create!(owner: owner, handle: "a", oauth_client_id: "stream-a")
    @recipient = Agent.create!(owner: other, handle: "b", oauth_client_id: "stream-b")
    @task = Task.create!(organization: organization, caller_agent: @caller, recipient_agent: @recipient, execution_route: "native",
      context_id: "public-context", state: "TASK_STATE_SUBMITTED", status_at: Time.current)
    @relay = RelayTask.create!(task: @task, organization: organization, caller_agent: @caller, recipient_agent: @recipient,
      endpoint_url: "https://native.example.com/a2a", resource: "https://native.example.com/a2a", generation: 1,
      native_task_id: "private-task", native_context_id: "private-context")
    @snapshot = { "id" => "private-task", "contextId" => "private-context", "status" => { "state" => "TASK_STATE_SUBMITTED", "timestamp" => "2000-01-01T00:00:00Z" } }
    @relay.import_snapshot!(@snapshot)
  end

  teardown { A2a::Waiters.reset! }

  test "status timestamps are gateway observations, never the upstream clock" do
    stream = A2a::Stream.task(@task, viewer: @caller)
    @snapshot["status"]["state"] = "TASK_STATE_COMPLETED"
    @relay.import_snapshot!(@snapshot)
    event = collect(stream).last.fetch("statusUpdate")
    assert_equal A2a::Serializer.timestamp(@task.reload.status_at), event.dig("status", "timestamp")
    assert_equal "2000-01-01T00:00:00Z", @task.events.order(:id).last.upstream_timestamp
    assert_equal @task.id, event["taskId"]
    assert_equal @task.context_id, event["contextId"]
  end

  test "section 4.2.2 snapshot base changes close old streams before new-base events" do
    first = A2a::Stream.task(@task, viewer: @caller)
    second = A2a::Stream.task(@task, viewer: @recipient)
    @snapshot["artifacts"] = [ { "artifactId" => "wire", "metadata" => { "x" => 1 }, "extensions" => [ "urn:output" ], "parts" => [ { "text" => "new base", "metadata" => { "part" => true } } ] } ]
    @snapshot["status"]["state"] = "TASK_STATE_COMPLETED"
    @relay.import_snapshot!(@snapshot)
    one = collect(first)
    two = collect(second)
    assert_equal 2, one.size
    assert_equal one, two
    assert_equal "RELAY_SNAPSHOT_BOUNDARY", one.last.dig("error", "data", 0, "reason")
    assert_equal @task.id, one.last.dig("error", "data", 0, "metadata", "taskId")
    fresh = collect(A2a::Stream.task(@task.reload, viewer: @caller)).sole.fetch("task")
    assert_equal "TASK_STATE_COMPLETED", fresh.dig("status", "state")
    assert_equal "wire", fresh.dig("artifacts", 0, "artifactId")
    assert_equal({ "x" => 1 }, fresh.dig("artifacts", 0, "metadata"))
    assert_equal [ "urn:output" ], fresh.dig("artifacts", 0, "extensions")
    assert fresh.dig("artifacts", 0, "parts", 0, "metadata", "part")
  end

  test "immutable persisted delta payloads replay identical chunks twice in order for every viewer" do
    # This proves record replay, not a live native SSE/model round trip.
    first = A2a::Stream.task(@task, viewer: @caller)
    second = A2a::Stream.task(@task, viewer: @recipient)
    payload = { "taskId" => @task.id, "contextId" => @task.context_id,
      "artifact" => { "artifactId" => "wire", "parts" => [ { "text" => "same" } ] }, "append" => true, "lastChunk" => false }
    2.times { @task.events.create!(kind: "artifact", payload: payload, created_at: Time.current) }
    @snapshot["status"]["state"] = "TASK_STATE_COMPLETED"
    @relay.import_snapshot!(@snapshot)
    one = collect(first)
    two = collect(second)
    assert_equal one, two
    assert_equal [ payload, payload ], one.filter_map { |event| event["artifactUpdate"] }
    row = @task.events.find_by!(kind: "artifact")
    assert_not row.update(payload: { "rewritten" => true })
    assert_equal payload, row.reload.payload
  end

  test "Get/List metadata distinguishes actual freshness, gap and executor state" do
    output = A2a::Exchange.get_task(viewer: @caller, id: @task.id, recipient: @recipient)
    assert_equal "native", output.dig("metadata", "concourse.route")
    assert output.dig("metadata", "concourse.gap")
    assert_not output.dig("metadata", "concourse.stale")
    travel 61.seconds do
      output = A2a::Exchange.get_task(viewer: @caller, id: @task.id, recipient: @recipient)
      assert output.dig("metadata", "concourse.stale")
      assert_equal "TASK_STATE_SUBMITTED", output.dig("status", "state")
      listed = A2a::Exchange.list_tasks(viewer: @caller, recipient: @recipient)
      assert_equal output["metadata"], listed["tasks"].sole["metadata"]
    end
  end

  test "native Message association can omit taskId while preserving creator ID and part metadata" do
    message = @task.messages.create!(role: "ROLE_AGENT", sender_agent: @recipient, native_message_id: "creator-id",
      native_context_id: "private-context", parts: [ { "text" => "", "metadata" => { "x" => 1 } } ])
    wire = A2a::Serializer.message(message)
    assert_equal "creator-id", wire["messageId"]
    assert_equal "public-context", wire["contextId"]
    assert_not wire.key?("taskId")
    assert_equal "", wire.dig("parts", 0, "text")
    assert_equal({ "x" => 1 }, wire.dig("parts", 0, "metadata"))
  end

  private

  def collect(stream)
    events = []
    A2a::Exchange.with_limits(poll: 0.01, stream: 0.1) { stream.each { |event| events << event if event } }
    events
  rescue A2a::RelayError => error
    events << { "error" => error.to_h.deep_stringify_keys }
  end
end
