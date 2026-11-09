require "test_helper"

class TaskRelayGuardsTest < ActiveSupport::TestCase
  setup do
    @organization = Organization.default
    owner = User.create!(ajent_sub: "guards-owner", handle: "owner", organizations: [ @organization ])
    @caller = Agent.create!(owner: owner, handle: "caller")
    @recipient = Agent.create!(owner: owner, handle: "recipient")
  end

  test "legacy constructors and database default remain executable inbox work" do
    task = Task.open!(recipient: @recipient, caller: @caller)
    assert task.inbox?
    assert task.actionable?
    assert task.content_changed_at.present?
    assert_equal "inbox", Task.column_defaults["execution_route"]
    assert_not task.update(execution_route: "native")
    assert_equal "inbox", task.reload.execution_route
  end

  test "held and native tasks cannot be picked up, locally replied to, or canceled" do
    %w[native held].each do |route|
      task = task_for(route)
      assert_not task.actionable?
      assert_nil task.waiting_side
      assert_empty @recipient.waiting_tasks(Task.visible_to(@recipient))
      assert_not Task.awaiting_owner(@recipient.owner).exists?(task.id)
      assert_raises(Task::NotInbox) { task.transition_to!("TASK_STATE_WORKING", by: @recipient) }
      assert_raises(Task::NotInbox) { task.restate!(by: @recipient) }
      assert_raises(Task::NotInbox) { task.cancel_by_caller!(by: @caller) }
      assert_raises(Task::NotInbox) { Message.record!(task: task, role: "ROLE_AGENT", sender: @recipient, parts: [ { "text" => "reply" } ]) }
      assert_raises(Task::NotInbox) { Artifact.record!(task: task, by: @recipient, parts: [ { "text" => "result" } ]) }
      assert_raises(A2a::Error) { task.respond_for_owner!(@recipient.owner, side: "recipient", text: "reply", state: "TASK_STATE_COMPLETED") }
      assert_not task.update(execution_route: "inbox")
      assert_equal route, task.reload.execution_route
      assert_empty task.messages
      assert_empty task.artifacts
    end
  end

  test "unconfirmed input stays blocked but real native input requests remain visible to caller owners" do
    task = task_for("native", state: "TASK_STATE_INPUT_REQUIRED")
    assert_equal "caller", task.waiting_side
    assert Task.awaiting_owner(@caller.owner).exists?(task.id)
    receipt = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, task: task, execution_route: "native",
      route_snapshot: { endpoint_url: "https://native.example/a2a", resource: "https://native.example/a2a", generation: 1 },
      message: { "messageId" => "unconfirmed", "parts" => [ { "text" => "input" } ] })
    receipt.start_sending!(holder: "h", deadline_at: 10.seconds.from_now)
    receipt.hold!(holder: "h", fence: receipt.fence)
    assert_nil task.waiting_side
    assert_not Task.awaiting_owner(@caller.owner).exists?(task.id)
    assert_raises(A2a::Error) { task.respond_for_owner!(@caller.owner, side: "caller", text: "bypass") }
  end

  test "observation writes do not extend native or held retention, and mappings/content disappear but fences remain" do
    native = task_for("native")
    held = task_for("held")
    receipt = RelayDelivery.reserve!(caller: @caller, recipient: @recipient,
      message: { "messageId" => "expiry", "parts" => [ { "text" => "expire-sentinel" } ] })
    inbox = Task.open!(recipient: @recipient, caller: @caller)
    receipt.accept!(task: inbox, result: { "task" => { "id" => inbox.id } })
    mapping = RelayContext.map!(caller: @caller, recipient: @recipient, generation: 1,
      public_context_id: "public", native_context_id: "upstream")
    native.messages.create!(role: "ROLE_USER", sender_agent: @caller, parts: [ { "text" => "expire-sentinel" } ])
    native.artifacts.create!(native_artifact_id: "output", parts: [ { "text" => "expire-sentinel" } ])
    native.events.create!(kind: "status", payload: { "content" => "expire-sentinel" })
    [ native, held ].each { |task| task.update_columns(content_changed_at: 31.days.ago, updated_at: Time.current) }
    inbox.update_columns(updated_at: 31.days.ago)
    mapping.update_columns(content_changed_at: 31.days.ago)
    PurgeExpiredTasksJob.perform_now
    assert_not @organization.tasks.exists?(native.id)
    assert_not @organization.tasks.exists?(held.id)
    assert_not @organization.tasks.exists?(inbox.id)
    assert_empty Message.where(task_id: native.id)
    assert_empty Artifact.where(task_id: native.id)
    assert_empty TaskEvent.where(task_id: native.id)
    assert_not RelayContext.exists?(mapping.id)
    assert receipt.reload.expired_at?
    assert_not_includes receipt.attributes.to_json, "expire-sentinel"
  end

  test "standalone receipts expire to content-free dedupe fences without a task" do
    receipt = RelayDelivery.reserve!(caller: @caller, recipient: @recipient,
      message: { "messageId" => "direct", "parts" => [ { "text" => "expire-sentinel" } ] })
    receipt.accept!(result: { "message" => { "parts" => [ { "text" => "expire-sentinel" } ] } })
    receipt.update_columns(content_changed_at: 31.days.ago, updated_at: Time.current)
    PurgeExpiredTasksJob.perform_now
    assert receipt.reload.expired_at?
    assert_nil receipt.task_id
    assert_nil receipt.request_payload
    assert_nil receipt.result_payload
    assert_equal "accepted", receipt.outcome
    assert_not_includes receipt.attributes.to_json, "expire-sentinel"
  end

  private

  def task_for(route, **attrs)
    Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient, execution_route: route, **attrs)
  end
end
