require "test_helper"

# Live inbox behaviour under dropped connections, restarts and long absences.
# Relay activation stays OFF: this is the shipped mailbox path. A lost response
# is retried with the same messageId (A2A §3.3.1 leaves idempotency to us).
class InboxDisconnectScenariosTest < ActiveSupport::TestCase
  setup do
    organization = Organization.default
    @caller = Agent.create!(owner: User.create!(ajent_sub: "drop-caller", handle: "drop-caller", organizations: [ organization ]), handle: "caller")
    @recipient = Agent.create!(owner: User.create!(ajent_sub: "drop-recipient", handle: "drop-recipient", organizations: [ organization ]), handle: "worker")
    A2a::Waiters.reset!
  end

  teardown { A2a::Waiters.reset! }

  test "a send interrupted after reservation leaves nothing behind and the same messageId retry delivers once" do
    original = Message.method(:record!)
    failed = false
    Message.define_singleton_method(:record!) do |**arguments|
      unless failed
        failed = true
        raise IOError, "process died mid-delivery"
      end
      original.call(**arguments)
    end
    assert_raises(IOError) { send_message("interrupted") }
    assert_equal 0, RelayDelivery.count
    assert_equal 0, Task.count

    task = send_message("interrupted")
    assert_equal "TASK_STATE_SUBMITTED", task["status"]["state"]
    assert_equal 1, Task.count
    assert_equal 1, Message.count
    assert_equal "accepted", RelayDelivery.sole.phase
    assert_equal task["id"], A2a::Exchange.next_task(@recipient).id
  ensure
    Message.define_singleton_method(:record!, original)
  end

  test "a lost response retried with the same messageId returns the same task without a second message" do
    first = send_message("lost-response")
    again = send_message("lost-response")
    assert_equal first["id"], again["id"]
    assert_equal 1, Task.count
    assert_equal 1, Message.count
    assert_equal 1, A2a::Exchange.inbox(@recipient).size
  end

  test "a continuation retried after a lost response is recorded once and still answers the question" do
    task_id = send_message("question")["id"]
    A2a::Exchange.reply(agent: @recipient, task_id: task_id, parts: [ { "text" => "which one?" } ], state: "TASK_STATE_INPUT_REQUIRED")
    travel 1.second
    send_message("answer", task_id: task_id)
    send_message("answer", task_id: task_id)
    task = Task.find(task_id)
    assert_equal 2, task.messages.where(role: "ROLE_USER").count
    assert task.actionable?, "the recipient must see the caller's answer"
    assert_equal task_id, A2a::Exchange.next_task(@recipient).id
  end

  test "a reused messageId with a different body returns the original task, as before receipts" do
    first = send_message("reused")
    message = { "messageId" => "reused", "role" => "ROLE_USER", "parts" => [ { "text" => "different" } ] }
    again = A2a::Exchange.send_message(caller: @caller, recipient: @recipient, message: message, configuration: { "returnImmediately" => true })
    assert_equal first["id"], again["id"]
    assert_equal 1, Message.count
    other = Agent.create!(owner: @recipient.owner, handle: "other-worker")
    assert_raises(A2a::Error) do
      A2a::Exchange.send_message(caller: @caller, recipient: other, message: message, configuration: { "returnImmediately" => true })
    end
  end

  test "a message sent before this deploy and retried after it reuses the existing task" do
    task = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: task, role: "ROLE_USER", sender: @caller, message_id: "pre-deploy", parts: [ { "text" => "hello" } ])
    assert_equal task.id, send_message("pre-deploy")["id"]
    assert_equal 1, Task.count
    assert_equal 1, Message.count
  end

  test "a worker that drops mid-wait frees its slot and the task stays for the next poll" do
    waiter = Thread.new do
      A2a::Exchange.with_limits(inbox: 30, poll: 0.05) { A2a::Exchange.next_task(@recipient) }
    end
    sleep 0.2
    waiter.kill.join
    assert A2a::Waiters.acquire(@recipient.organization_id), "abandoned wait must release its slot"
    A2a::Waiters.release(@recipient.organization_id)

    sent = send_message("after-drop")
    assert_equal sent["id"], A2a::Exchange.with_limits(inbox: 0) { A2a::Exchange.next_task(@recipient) }.id
  end

  test "a caller that drops a blocking send frees its slot and the work stays queued" do
    blocker = Thread.new do
      A2a::Exchange.with_limits(blocking: 30, poll: 0.05) do
        A2a::Exchange.send_message(caller: @caller, recipient: @recipient,
          message: { "messageId" => "blocking", "role" => "ROLE_USER", "parts" => [ { "text" => "wait" } ] })
      end
    end
    sleep 0.3
    blocker.kill.join
    assert_equal 1, A2a::Exchange.inbox(@recipient).size
    assert_equal "TASK_STATE_SUBMITTED", Task.sole.state
    A2a::Waiters.limit = 1
    assert A2a::Waiters.acquire, "abandoned blocking send must release its slot"
  ensure
    A2a::Waiters.limit = nil
  end

  test "a stream reader that drops frees its slot without changing the task" do
    task = Task.find(send_message("streamed")["id"])
    stream = A2a::Stream.task(task, viewer: @caller)
    reader = Thread.new { A2a::Exchange.with_limits(poll: 0.05, stream: 30) { stream.each { } } }
    sleep 0.3
    reader.kill.join
    A2a::Waiters.limit = 1
    assert A2a::Waiters.acquire
    assert_equal "TASK_STATE_SUBMITTED", task.reload.state
  ensure
    A2a::Waiters.limit = nil
  end

  test "a long-offline worker returns to every queued task oldest first, and replies reach a caller who was also away" do
    ids = %w[first second third].map do |name|
      travel 1.minute
      send_message(name)["id"]
    end
    travel 29.days
    PurgeExpiredTasksJob.perform_now
    assert_equal 3, A2a::Exchange.inbox(@recipient).size

    picked = ids.map do |expected|
      task = A2a::Exchange.with_limits(inbox: 0) { A2a::Exchange.next_task(@recipient) }
      assert_equal expected, task.id
      A2a::Exchange.reply(agent: @recipient, task_id: task.id, parts: [ { "text" => "done" } ], state: "TASK_STATE_COMPLETED")
      task.id
    end
    assert_equal ids, picked
    assert_nil A2a::Exchange.with_limits(inbox: 0) { A2a::Exchange.next_task(@recipient) }

    since = 1.hour.ago.utc.iso8601
    replies = A2a::Exchange.list_tasks(viewer: @caller, filters: { "statusTimestampAfter" => since })
    assert_equal ids.sort, replies["tasks"].map { |task| task["id"] }.sort
    assert replies["tasks"].all? { |task| task.dig("status", "state") == "TASK_STATE_COMPLETED" }
  end

  test "work untouched past retention expires, and its messageId stays fenced instead of re-running" do
    send_message("ancient")
    travel 31.days
    PurgeExpiredTasksJob.perform_now
    assert_equal 0, Task.count
    error = assert_raises(A2a::RelayError) { send_message("ancient") }
    assert_equal "RELAY_RECORD_EXPIRED", error.data.first.fetch("reason")
    assert_equal 0, Task.count
    assert send_message("fresh")["id"]
  end

  test "pre-receipt messages remain content-free fences after purge instead of creating new work" do
    task = Task.open!(caller: @caller, recipient: @recipient)
    %w[legacy legacy-continuation].each do |id|
      Message.record!(task: task, role: "ROLE_USER", sender: @caller, message_id: id,
        parts: [ { "text" => "legacy-secret" } ], metadata: { "private" => "legacy-metadata" })
    end
    Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "unkeyed-secret" } ])
    Message.record!(task: task, role: "ROLE_AGENT", sender: @recipient, message_id: "agent-id",
      parts: [ { "text" => "agent-secret" } ])
    Artifact.record!(task: task, by: @recipient, parts: [ { "text" => "artifact-secret" } ])
    assert_equal 0, RelayDelivery.count
    travel 31.days
    PurgeExpiredTasksJob.perform_now

    assert_equal 0, Task.count
    assert_equal 0, Message.count
    assert_equal 0, Artifact.count
    assert_equal 0, TaskEvent.count
    assert_equal 2, RelayDelivery.count
    RelayDelivery.all.each do |receipt|
      assert receipt.expired_at?
      assert_equal "accepted", receipt.phase
      assert_equal "inbox", receipt.execution_route
      assert_equal task.id, receipt.public_task_id
      assert_nil receipt.task_id
      assert_nil receipt.request_payload
      assert_nil receipt.result_payload
      assert_not_includes receipt.attributes.to_json, "secret"
      assert_not_includes receipt.attributes.to_json, "legacy"
    end
    %w[legacy legacy-continuation].each do |id|
      error = assert_raises(A2a::RelayError) { send_message(id) }
      assert_equal "RELAY_RECORD_EXPIRED", error.data.first.fetch("reason")
      assert_equal 0, Task.count
    end
    fences = RelayDelivery.order(:id).pluck(:id, :fence, :expired_at)
    PurgeExpiredTasksJob.perform_now
    assert_equal fences, RelayDelivery.order(:id).pluck(:id, :fence, :expired_at)

    # The fence belongs to this caller, not every caller using that ID (§3.3.1).
    other = Agent.create!(owner: @caller.owner, handle: "other-caller")
    answer = A2a::Exchange.send_message(caller: other, recipient: @recipient,
      message: { "messageId" => "legacy", "role" => "ROLE_USER", "parts" => [ { "text" => "different" } ] },
      configuration: { "returnImmediately" => true })
    assert_equal "TASK_STATE_SUBMITTED", answer.dig("status", "state")
    assert_equal 1, Task.count
  end

  test "a task whose history outgrows the receipt limit still accepts a short follow-up and replays it once" do
    task_id = send_message("big-start")["id"]
    big = "x" * 600.kilobytes
    4.times do |index|
      A2a::Exchange.reply(agent: @recipient, task_id: task_id, parts: [ { "text" => "#{index}#{big}" } ],
        state: index == 3 ? "TASK_STATE_INPUT_REQUIRED" : nil)
    end
    assert_operator A2a::Serializer.task(Task.find(task_id)).to_json.bytesize, :>, RelayDelivery::PAYLOAD_LIMIT
    travel 1.second

    answered = send_message("big-answer", task_id: task_id)
    again = send_message("big-answer", task_id: task_id)

    assert_equal task_id, answered["id"]
    assert_equal task_id, again["id"]
    assert_equal 1, Message.where(task_id: task_id, client_message_id: "big-answer").count
    assert_equal task_id, A2a::Exchange.next_task(@recipient).id
    receipt = RelayDelivery.find_by!(message_id_digest: Digest::SHA256.hexdigest("big-answer"))
    assert_operator receipt.result_payload.to_json.bytesize, :<, 1.kilobyte, "an inbox receipt references its task"
  end

  test "a receipt written before this release, holding a full task snapshot, still replays the live task" do
    task_id = send_message("snapshot")["id"]
    receipt = RelayDelivery.sole
    receipt.update_columns(result_payload: { "task" => A2a::Serializer.task(Task.find(task_id)) })
    A2a::Exchange.reply(agent: @recipient, task_id: task_id, parts: [ { "text" => "done" } ], state: "TASK_STATE_COMPLETED")

    replayed = send_message("snapshot")

    assert_equal task_id, replayed["id"]
    assert_equal "TASK_STATE_COMPLETED", replayed.dig("status", "state")
    assert_equal 1, Message.where(task_id: task_id, role: "ROLE_USER").count
  end

  private

  def send_message(id, task_id: nil)
    message = { "messageId" => id, "role" => "ROLE_USER", "parts" => [ { "text" => "text #{id}" } ] }
    message["taskId"] = task_id if task_id
    A2a::Exchange.send_message(caller: @caller, recipient: @recipient, message: message,
      configuration: { "returnImmediately" => true })
  end
end
