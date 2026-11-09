require "test_helper"

class RelayNativeOrderTest < ActiveSupport::TestCase
  setup do
    organization = Organization.default
    owner = User.create!(ajent_sub: "order-owner", handle: "order-owner", organizations: [ organization ])
    caller = Agent.create!(owner: owner, handle: "caller")
    recipient = Agent.create!(owner: owner, handle: "recipient")
    @task = Task.create!(organization: organization, caller_agent: caller, recipient_agent: recipient, execution_route: "native")
    @relay = RelayTask.create!(task: @task, organization: organization, caller_agent: caller, recipient_agent: recipient,
      endpoint_url: "https://native.invalid/a2a", resource: "https://native.invalid/a2a", generation: 1,
      native_task_id: "native-task", native_context_id: "native-context")
  end

  test "later full snapshots preserve native history and artifact order rather than first observation clocks" do
    @relay.import_snapshot!(snapshot([ "last" ]))
    original_event = @task.events.sole.payload.deep_dup
    travel 5.seconds do
      @relay.import_snapshot!(snapshot([ "first", "last" ]))
    end
    payload = A2a::Serializer.task(@task.reload)
    assert_equal %w[first last], payload.fetch("history").map { |message| message.fetch("messageId") }
    assert_equal %w[first last], payload.fetch("artifacts").map { |artifact| artifact.fetch("artifactId") }
    assert_equal [ "last" ], A2a::Serializer.task(@task, history_length: 1).fetch("history").map { |message| message.fetch("messageId") }
    assert_equal original_event, @task.events.order(:id).first.payload
    assert_equal "snapshot_boundary", @task.events.order(:id).last.kind
    assert_not @task.events.order(:id).last.settlement_evidence
    assert_equal %w[first last], A2a::Serializer.task(Task.find(@task.id)).fetch("history").map { |message| message.fetch("messageId") }
  end

  test "SSE bases and new deltas share durable native order and do not move an existing status message" do
    assert @relay.acquire_observation!(holder: "observer")
    fence = @relay.fence
    @relay.observe_native_event!(payload: { "task" => snapshot([ "last" ]) }, holder: "observer", fence: fence)
    expanded = snapshot(%w[first last])
    expanded["status"]["message"] = expanded["history"].first
    @relay.observe_native_event!(payload: { "task" => expanded }, holder: "observer", fence: fence)
    @relay.observe_native_event!(payload: { "artifactUpdate" => { "taskId" => "native-task", "contextId" => "native-context",
      "artifact" => { "artifactId" => "new", "parts" => [ { "text" => "new" } ] } } }, holder: "observer", fence: fence)
    @relay.observe_native_event!(payload: { "message" => snapshot([ "new" ])["history"].sole }, holder: "observer", fence: fence)
    payload = A2a::Serializer.task(@task.reload)
    assert_equal %w[first last new], payload.fetch("history").map { |message| message.fetch("messageId") }
    assert_equal %w[first last new], payload.fetch("artifacts").map { |artifact| artifact.fetch("artifactId") }
    assert_equal "first", payload.dig("status", "message", "messageId")
  end

  test "a bounded history suffix retains the order of the previously known prefix" do
    @relay.import_snapshot!(snapshot(%w[first middle last]))
    @relay.import_snapshot!(snapshot(%w[last new]))
    payload = A2a::Serializer.task(@task.reload)
    assert_equal %w[first middle last new], payload.fetch("history").map { |message| message.fetch("messageId") }
    assert_equal %w[last new], payload.fetch("artifacts").map { |artifact| artifact.fetch("artifactId") }
  end


  private

  def snapshot(ids)
    { "id" => "native-task", "contextId" => "native-context", "status" => { "state" => "TASK_STATE_WORKING" },
      "history" => ids.map { |id| { "messageId" => id, "taskId" => "native-task", "contextId" => "native-context",
        "role" => "ROLE_AGENT", "parts" => [ { "text" => id } ] } },
      "artifacts" => ids.map { |id| { "artifactId" => id, "parts" => [ { "text" => id } ] } } }
  end
end
