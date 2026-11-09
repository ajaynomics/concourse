require "test_helper"

class PurgeExpiredTasksJobTest < ActiveSupport::TestCase
  test "deletes tasks untouched for 30 days and emits only a count" do
    owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    caller = Agent.create!(owner: owner, handle: "codex", oauth_client_id: "client-a")
    recipient = Agent.create!(owner: owner, handle: "pi", oauth_client_id: "client-b")
    old = Task.open!(recipient: recipient, caller: caller)
    Message.record!(task: old, role: "ROLE_USER", sender: caller, parts: [ { "text" => "stale secret" } ])
    Artifact.record!(task: old, by: recipient, parts: [ { "text" => "stale artifact" } ])
    old.update_columns(updated_at: 31.days.ago)
    fresh = Task.open!(recipient: recipient, caller: caller)
    capture_events("concourse.retention.purged") do |events|
      PurgeExpiredTasksJob.perform_now

      assert_nil Task.find_by(id: old.id)
      assert_equal 0, Message.where(task_id: old.id).count
      assert_equal 0, Artifact.where(task_id: old.id).count
      assert Task.exists?(fresh.id)
      assert_equal 1, events.sole[:payload][:count]
      assert_not events.sole.inspect.include?("stale")
    end
  end

  test "purge preserves existing receipts and fences legacy messages even after parties move" do
    owner = User.create!(ajent_sub: "moved", handle: "moved", organizations: [ Organization.default ])
    caller = Agent.create!(owner: owner, handle: "caller")
    recipient = Agent.create!(owner: owner, handle: "recipient")
    message = { "messageId" => "receipt-era", "role" => "ROLE_USER", "parts" => [ { "text" => "receipt-secret" } ] }
    answer = A2a::Exchange.send_message(caller: caller, recipient: recipient, message: message,
      configuration: { "returnImmediately" => true })
    task = Task.find(answer.fetch("id"))
    receipt = RelayDelivery.sole
    original_digest = receipt.request_digest
    original_fence = receipt.fence
    Message.record!(task: task, role: "ROLE_USER", sender: caller, message_id: "legacy-moved",
      parts: [ { "text" => "legacy-secret" } ])
    task.transition_to!("TASK_STATE_COMPLETED", by: recipient)
    destination = Organization.create!(name: "Destination", slug: "destination")
    owner.organizations << destination
    caller.update!(organization: destination)
    recipient.update!(organization: destination)
    travel 31.days
    PurgeExpiredTasksJob.perform_now

    assert_equal 0, Task.count
    assert_equal 0, Message.count
    assert_equal 2, RelayDelivery.count
    receipt.reload
    assert_equal original_digest, receipt.request_digest
    assert_equal original_fence + 1, receipt.fence
    assert receipt.expired_at?
    assert_nil receipt.request_payload
    assert_nil receipt.result_payload
    legacy = RelayDelivery.find_by!(message_id_digest: Digest::SHA256.hexdigest("legacy-moved"))
    assert_equal task.organization_id, legacy.organization_id
    assert_not_equal destination.id, legacy.organization_id
    assert_equal caller.id, legacy.caller_agent_id
    assert_equal recipient.id, legacy.recipient_agent_id
    assert legacy.expired_at?
    assert_nil legacy.request_payload
    assert_nil legacy.result_payload
    assert_not_includes legacy.attributes.to_json, "secret"
  end

  test "a failed purge rolls back legacy tombstones with message deletion" do
    owner = User.create!(ajent_sub: "rollback", handle: "rollback", organizations: [ Organization.default ])
    caller = Agent.create!(owner: owner, handle: "caller")
    recipient = Agent.create!(owner: owner, handle: "recipient")
    task = Task.open!(caller: caller, recipient: recipient)
    2.times do |index|
      Message.record!(task: task, role: "ROLE_USER", sender: caller, message_id: "legacy-#{index}",
        parts: [ { "text" => "work" } ])
    end
    travel 31.days
    original = RelayDelivery.method(:expire_legacy_message!)
    inserted = 0
    RelayDelivery.define_singleton_method(:expire_legacy_message!) do |message|
      original.call(message)
      inserted += 1
      raise IOError, "purge interrupted" if inserted == 2
    end

    assert_raises(IOError) { PurgeExpiredTasksJob.perform_now }
    assert_equal 0, RelayDelivery.count
    assert Task.exists?(task.id)
    assert_equal 2, task.messages.count
  ensure
    RelayDelivery.define_singleton_method(:expire_legacy_message!, original) if original
  end
end
