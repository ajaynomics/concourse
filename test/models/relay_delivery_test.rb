require "test_helper"

class RelayDeliveryTest < ActiveSupport::TestCase
  setup do
    @organization = Organization.default
    @owner = User.create!(ajent_sub: "foundation-a", handle: "sender", organizations: [ @organization ])
    other = User.create!(ajent_sub: "foundation-b", handle: "receiver", organizations: [ @organization ])
    @caller = Agent.create!(owner: @owner, handle: "a")
    @recipient = Agent.create!(owner: other, handle: "b")
    @message = { "messageId" => "caller-id", "role" => "ROLE_USER", "parts" => [ { "text" => "content-sentinel" } ] }
    @route = { endpoint_url: "https://native.example/a2a", resource: "https://native.example/a2a", generation: 1 }
  end

  test "inbox reservation deduplicates by caller and delivery data, not JSON object order" do
    first = reserve
    assert first.previously_new_record?
    second = reserve(message: @message.to_a.reverse.to_h)
    assert_equal first.id, second.id
    assert_not second.previously_new_record?
    assert_equal "inbox", first.execution_route
    assert_equal Digest::SHA256.hexdigest("caller-id"), first.message_id_digest
    assert_raises(RelayDelivery::Pending) { second.replay! }
    # Inbox reuse keeps the pre-receipt contract: the original, whatever the body.
    assert_equal first.id, reserve(message: @message.merge("contextId" => "changed")).id
    assert_equal first.id, reserve(message: @message.merge("parts" => [ { "text" => "other" } ])).id
    native_message = @message.merge("messageId" => "native-id")
    native(message: native_message)
    assert_raises(RelayDelivery::Mismatch) { native(message: native_message.merge("contextId" => "changed")) }
    assert_raises(RelayDelivery::Mismatch) { native(message: native_message.merge("taskId" => "changed")) }
    peer = Agent.create!(owner: @owner, handle: "another")
    assert_raises(RelayDelivery::Mismatch) { reserve(recipient: peer) }
    assert_not_equal first.id, reserve(caller: peer).id
  end

  test "sending has one holder, holds cannot be reclaimed, and late verified acceptance keeps its route" do
    receipt = native
    receipt.start_sending!(holder: "first", deadline_at: 10.seconds.from_now)
    fence = receipt.fence
    assert_raises(RelayDelivery::Pending) { receipt.start_sending!(holder: "second", deadline_at: 10.seconds.from_now) }
    assert_raises(RelayDelivery::LostFence) { receipt.hold!(holder: "second", fence: fence) }
    held = tracking_task(receipt)
    receipt.hold!(holder: "first", fence: fence, task: held)
    assert_raises(RelayDelivery::Pending) { receipt.replay! }
    assert_raises(RelayDelivery::Pending) { receipt.start_sending!(holder: "first", deadline_at: 10.seconds.from_now) }
    assert_raises(RelayDelivery::LostFence) { receipt.fallback_to_inbox!(holder: "first", fence: fence, evidence: :tcp_refused) }
    receipt.accept!(holder: "first", fence: fence, task: held, result: { "task" => { "id" => held.id } })
    assert_equal "accepted", receipt.outcome
    assert_equal "native", receipt.execution_route
    assert_equal "held", held.reload.execution_route
    assert_equal held.id, receipt.replay!.dig("task", "id")
    assert_not receipt.update(phase: "reserved")
  end

  test "only initial positive pre-HTTP evidence permits fallback, once" do
    receipt = native
    receipt.start_sending!(holder: "first", deadline_at: 10.seconds.from_now)
    fence = receipt.fence
    assert_raises(ArgumentError) { receipt.fallback_to_inbox!(holder: "first", fence: fence, evidence: :read_timeout) }
    receipt.fallback_to_inbox!(holder: "first", fence: fence, evidence: :tcp_refused)
    assert_equal "inbox", receipt.execution_route
    assert_equal "unsent", receipt.outcome
    assert_operator receipt.fence, :>, fence
    assert_raises(RelayDelivery::LostFence) { receipt.hold!(holder: "first", fence: fence) }
    task = Task.open!(recipient: @recipient, caller: @caller)
    receipt.accept!(task: task, result: { "task" => { "id" => task.id } })
    assert_equal task.id, receipt.public_task_id
    assert_raises(RelayDelivery::LostFence) { receipt.accept!(task: task, result: {}) }

    continued = native(message: @message.merge("messageId" => "continuation", "taskId" => tracking_native.id), task: tracking_native)
    continued.start_sending!(holder: "followup", deadline_at: 10.seconds.from_now)
    assert_raises(RelayDelivery::Mismatch) { continued.fallback_to_inbox!(holder: "followup", fence: continued.fence, evidence: :tcp_refused) }
  end

  test "configuration rejection and orphan recovery never reopen dispatch" do
    receipt = native
    receipt.reject_reserved!(result: { "error" => "configuration" })
    assert_equal "configuration_rejected", receipt.outcome
    assert_raises(RelayDelivery::Pending) { receipt.start_sending!(holder: "h", deadline_at: 10.seconds.from_now) }
    assert_equal "configuration", receipt.replay!["error"]
    assert_raises(RelayDelivery::LostFence) { receipt.reject_reserved!(result: {}) }

    reserved = native(message: @message.merge("messageId" => "reserved-crash"))
    sending = native(message: @message.merge("messageId" => "sending-crash"))
    sending.start_sending!(holder: "dead", deadline_at: 10.seconds.from_now)
    travel 16.seconds do
      reserved.recover_expired_reservation!
      sending.recover_expired_holder!
      assert_equal "abandoned", reserved.outcome
      assert_equal "held", sending.phase
      assert_raises(RelayDelivery::Pending) { reserved.start_sending!(holder: "again", deadline_at: 10.seconds.from_now) }
      assert_raises(RelayDelivery::Pending) { sending.start_sending!(holder: "again", deadline_at: 10.seconds.from_now) }
    end
  end

  test "task deletion retains a content-free fence and expiry blocks all duplicates" do
    receipt = reserve
    task = Task.open!(recipient: @recipient, caller: @caller)
    receipt.accept!(task: task, result: { "task" => { "id" => task.id, "content" => "result-sentinel" } })
    task.destroy!
    receipt.reload
    assert_nil receipt.task_id
    assert_equal task.id, receipt.public_task_id
    assert_nil receipt.request_payload
    assert_nil receipt.result_payload
    assert receipt.expired_at?
    assert_not_includes receipt.attributes.to_json, "sentinel"
    assert_not_includes receipt.attributes.to_json, "caller-id"
    assert_raises(RelayDelivery::Expired) { reserve }
    assert_raises(RelayDelivery::Expired) { receipt.replay! }
    assert_raises(ActiveRecord::RecordNotDestroyed) { receipt.destroy! }
  end

  test "one pending mutation blocks input, held input allows a distinct cancel but not later input" do
    task = tracking_native
    first = native(task: task)
    assert_raises(RelayDelivery::Busy) { native(task: task, message: @message.merge("messageId" => "parallel")) }
    first.start_sending!(holder: "h", deadline_at: 10.seconds.from_now)
    first.hold!(holder: "h", fence: first.fence)
    assert_raises(RelayDelivery::Busy) { native(task: task, message: @message.merge("messageId" => "bypass")) }
    cancellation = native(task: task, operation: "CancelTask", message: { "messageId" => "cancel", "taskId" => task.id })
    assert_equal "reserved", cancellation.phase
  end

  test "removal cannot expose a duplicate or retain an acceptance body" do
    receipt = reserve
    @recipient.owner.memberships.find_by!(organization: @organization).destroy!
    assert_raises(Agent::Unadmitted) { reserve }
    receipt.accept!(result: { "secret" => "removed" })
    assert receipt.reload.expired_at?
    assert_nil receipt.result_payload
  end

  test "route snapshots are immutable and payloads are bounded" do
    receipt = native
    assert_not receipt.update(endpoint_url: "https://other.example/a2a")
    assert_not receipt.reload.update(execution_route: "inbox")
    assert_raises(ActiveRecord::RecordInvalid) { reserve(message: @message.merge("messageId" => "big", "parts" => [ { "text" => "a" * 1.megabyte } ])) }
  end

  private

  def reserve(**options)
    RelayDelivery.reserve!(**{ caller: @caller, recipient: @recipient, message: @message }.merge(options))
  end

  def native(**options)
    reserve(**{ execution_route: "native", route_snapshot: @route }.merge(options))
  end

  def tracking_task(receipt)
    Task.create!(id: receipt.reserved_task_id, organization: @organization, caller_agent: @caller, recipient_agent: @recipient, execution_route: "held")
  end

  def tracking_native
    @native_task ||= Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient, execution_route: "native")
  end
end
