require "test_helper"

class RelayTaskTest < ActiveSupport::TestCase
  setup do
    @organization = Organization.default
    owner = User.create!(ajent_sub: "import-owner", handle: "owner", organizations: [ @organization ])
    @caller = Agent.create!(owner: owner, handle: "caller")
    @recipient = Agent.create!(owner: owner, handle: "recipient")
    @task = Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      execution_route: "native", context_id: "public-context")
    @mapping = RelayTask.create!(task: @task, organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      endpoint_url: "https://native.example/a2a", resource: "https://native.example/a2a", generation: 1,
      native_task_id: "upstream-task", native_context_id: "upstream-context")
    @snapshot = { "id" => "upstream-task", "contextId" => "upstream-context",
      "status" => { "state" => "TASK_STATE_WORKING", "timestamp" => "2026-10-07T00:00:00Z" } }
  end

  test "terminal snapshot imports final artifacts, metadata and native creator IDs without inbox callbacks" do
    snapshot = @snapshot.deep_merge("metadata" => { "source" => "native" }, "status" => { "state" => "TASK_STATE_COMPLETED" })
    snapshot["history"] = [ agent_message ]
    snapshot["status"]["message"] = agent_message
    snapshot["artifacts"] = [ artifact("first"), artifact("second") ]
    @mapping.import_snapshot!(snapshot)
    assert_equal "TASK_STATE_COMPLETED", @task.reload.state
    assert_equal 2, @task.artifacts.count
    assert_equal "upstream-message", @task.messages.sole.wire_message_id
    assert_equal "native", @mapping.upstream_metadata["source"]
    assert_equal({ "keep" => true }, @task.artifacts.first.metadata)
    assert_equal [ "extension" ], @task.artifacts.first.extensions
    assert_equal 1, @task.events.count
    event = @task.events.sole
    assert_equal "status", event.kind
    assert_equal @task.id, event.payload["taskId"]
    assert_equal @task.context_id, event.payload.dig("status", "message", "contextId")
    assert_equal @task.id, event.payload.dig("status", "message", "taskId")
    assert_equal "2026-10-07T00:00:00Z", event.upstream_timestamp
    assert_raises(Task::NotInbox) { @task.cancel_by_caller!(by: @caller) }
  end

  test "identical and timestamp-only polls advance observations but not content status or event sequence" do
    @mapping.import_snapshot!(@snapshot)
    before = @task.reload.attributes.slice("content_changed_at", "status_at")
    events = @task.events.count
    changed = @mapping.changed_at
    travel 5.seconds do
      @mapping.import_snapshot!(@snapshot.deep_merge("status" => { "timestamp" => "2026-10-07T00:00:05Z" }))
      assert_operator @mapping.observed_at, :>, changed
      assert_equal changed, @mapping.changed_at
      assert_equal before, @task.reload.attributes.slice("content_changed_at", "status_at")
      assert_equal events, @task.events.count
    end
  end

  test "artifact replacement records an immutable boundary, not pretend append chunks" do
    initial = @snapshot.merge("artifacts" => [ artifact("first") ])
    @mapping.import_snapshot!(initial)
    original_event = @task.events.sole.payload.deep_dup
    travel 5.seconds do
      @mapping.import_snapshot!(@snapshot.merge("artifacts" => [ artifact("second") ]))
    end
    assert_equal [ "second" ], @task.artifacts.pluck(:native_artifact_id)
    assert_equal %w[status snapshot_boundary], @task.events.order(:id).pluck(:kind)
    assert_not @task.events.order(:id).last.settlement_evidence
    assert_equal original_event, @task.events.order(:id).first.payload
  end

  test "raw schema invalid parts, context mismatches and foreign references reject before storing" do
    invalid = @snapshot.merge("history" => [ agent_message.merge("parts" => [ { "text" => "one", "url" => "https://file.example" } ]) ])
    assert_raises(RelayTask::InvalidSnapshot) { @mapping.import_snapshot!(invalid) }
    assert_raises(RelayTask::InvalidSnapshot) { @mapping.import_snapshot!(@snapshot.merge("contextId" => "foreign")) }
    bad_ref = agent_message.merge("referenceTaskIds" => [ "unknown" ])
    assert_raises(RelayTask::InvalidSnapshot) { @mapping.import_snapshot!(@snapshot.merge("history" => [ bad_ref ])) }
    assert_empty @task.messages
    assert_empty @task.events
  end

  test "full user echoes reuse dispatcher rows and cannot invent caller activity or provenance" do
    request = { "messageId" => "user-message", "role" => "ROLE_USER", "parts" => [ { "text" => "input" } ],
      "metadata" => { "source" => "caller" }, "extensions" => [ "caller-extension" ] }
    RelayDelivery.reserve!(caller: @caller, recipient: @recipient, task: @task, message: request,
      execution_route: "native", route_snapshot: @mapping.route_snapshot)
    row = @task.messages.create!(role: "ROLE_USER", sender_agent: @caller, client_message_id: "user-message",
      parts: request["parts"], metadata: request["metadata"], extensions: request["extensions"], created_at: 1.minute.ago)
    echo = request.merge("taskId" => "upstream-task", "contextId" => "upstream-context")
    @mapping.import_snapshot!(@snapshot.merge("history" => [ echo ], "status" => { "state" => "TASK_STATE_INPUT_REQUIRED" }))
    assert_equal row.id, @task.messages.sole.id
    assert_equal "user-message", row.reload.native_message_id
    assert_not @task.reload.caller_answered?
    assert_raises(RelayTask::InvalidSnapshot) do
      @mapping.import_snapshot!(@snapshot.merge("history" => [ echo.merge("metadata" => { "spoof" => "identity" }) ]))
    end
    assert_raises(RelayTask::InvalidSnapshot) do
      @mapping.import_snapshot!(@snapshot.merge("history" => [ echo.merge("extensions" => []) ]))
    end
    assert_equal({ "source" => "caller" }, row.reload.metadata)
  end

  test "native IDs are unique within recipient generation, but not across servers" do
    duplicate = @mapping.dup
    duplicate.task = Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient, execution_route: "native")
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
    duplicate.generation = 2
    duplicate.save!
    assert_not_equal @mapping.task_id, duplicate.task_id
    assert_not @mapping.update(native_task_id: "different")
  end

  test "late acceptance imports into held task without exposing another executor" do
    held = Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient, execution_route: "held")
    mapping = @mapping.dup
    mapping.task = held
    mapping.generation = 2
    mapping.save!
    mapping.import_snapshot!(@snapshot)
    assert held.reload.held?
    assert_not held.actionable?
  end

  test "fenced imports reject expired leases and participant removal" do
    @mapping.update!(fence: 2, lease_holder: "job", lease_expires_at: 1.minute.from_now)
    assert_raises(RelayTask::LostLease) { @mapping.import_snapshot!(@snapshot, fence: 1) }
    @mapping.update!(lease_expires_at: 1.second.ago)
    assert_raises(RelayTask::LostLease) { @mapping.import_snapshot!(@snapshot, fence: 2) }
    @recipient.owner.memberships.find_by!(organization: @organization).destroy!
    assert_raises(Agent::Unadmitted) { @mapping.import_snapshot!(@snapshot) }
    assert_empty @task.events
  end

  private

  def agent_message
    { "messageId" => "upstream-message", "contextId" => "upstream-context", "taskId" => "upstream-task",
      "role" => "ROLE_AGENT", "parts" => [ { "text" => "done", "metadata" => { "part" => true } } ], "metadata" => { "keep" => true } }
  end

  def artifact(id)
    { "artifactId" => id, "parts" => [ { "url" => "https://file.example/#{id}", "mediaType" => "application/octet-stream" } ],
      "metadata" => { "keep" => true }, "extensions" => [ "extension" ] }
  end
end
