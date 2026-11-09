require_relative "native_relay_delivery_test"

class NativeRelayReviewRegressionTest < ActionDispatch::IntegrationTest
  include NativeRelayTestSupport
  setup { setup_native_relay }

  test "retained caller history remains evidence-bound after receipt content expires" do
    snapshot = nil
    response = ->(request, _) do
      snapshot = native_task.merge("history" => [ request.dig("params", "message").deep_dup ])
      native_response(request, result: { "task" => snapshot })
    end
    with_native(response: response) do
      body = rpc_native
      task = Task.find(body.dig("result", "task", "id"))
      delivery = task.relay_deliveries.sole
      delivery.expire!
      assert_nil delivery.reload.request_payload
      snapshot["status"]["state"] = "TASK_STATE_COMPLETED"
      task.relay_task.import_snapshot!(snapshot)
      assert_equal "TASK_STATE_COMPLETED", task.reload.state
      assert_equal 1, task.messages.count
      forged = snapshot.deep_dup
      forged["history"][0]["parts"] = [ { "text" => "invented caller input" } ]
      assert_raises(RelayTask::InvalidSnapshot) { task.relay_task.import_snapshot!(forged) }
    end
  end

  test "fresh direct Message continuation retains task but never supplies task state or reserved provenance" do
    status = nil
    response = ->(request, _) do
      result = if request.dig("params", "message", "taskId")
        { "message" => { "messageId" => "native-direct", "taskId" => "native-task", "contextId" => "native-context",
          "role" => "ROLE_AGENT", "parts" => [ { "text" => "answer", "metadata" => { "part" => true } } ],
          "metadata" => { "concourse.caller" => "spoofed", "concourse.via" => "owner", "keep" => true } } }
      else
        { "task" => native_task }
      end
      native_response(request, result: result)
    end
    with_native(response: response) do
      initial = rpc_native
      task = Task.find(initial.dig("result", "task", "id"))
      task.update_columns(content_changed_at: 31.days.ago)
      status = task.attributes.slice("state", "status_at")
      message = user_message(id: "direct-input", task_id: task.id, context_id: task.context_id)
      reply = rpc_native(message: message)
      assert_equal({ "keep" => true }, reply.dig("result", "message", "metadata"))
      assert_equal({ "part" => true }, reply.dig("result", "message", "parts", 0, "metadata"))
      assert_equal task.id, reply.dig("result", "message", "taskId")
      assert_equal status, task.reload.attributes.slice("state", "status_at")
      assert_operator task.content_changed_at, :>, 1.minute.ago
      assert_equal reply["result"], rpc_native(message: message)["result"]
      PurgeExpiredTasksJob.perform_now
      assert Task.exists?(task.id)
      assert_equal 2, @calls.size
    end
  end

  test "an absent native Task context remains absent while Message context is separately mapped" do
    response = ->(request, _) do
      snapshot = native_task(context: nil)
      snapshot["status"]["message"] = { "messageId" => "native-answer", "taskId" => "native-task",
        "contextId" => "message-context", "role" => "ROLE_AGENT", "parts" => [ { "text" => "answer" } ] }
      native_response(request, result: { "task" => snapshot })
    end
    with_native(response: response) do
      body = rpc_native
      assert_not body.key?("error")
      task = Task.find(body.dig("result", "task", "id"))
      assert_nil task.relay_task.native_context_id
      assert_not body.dig("result", "task").key?("contextId")
      assert_equal task.context_id, body.dig("result", "task", "status", "message", "contextId")
      assert_equal "message-context", task.organization.relay_contexts.where(public_context_id: task.context_id).sole.native_context_id
      assert_equal "message-context", task.status_message.native_context_id
    end
  end

  test "standard ID-free ErrorInfo refusals stay refusals, never fallback or uncertain acceptance" do
    error = { "code" => -32002, "message" => "Task not cancelable", "data" => [ {
      "@type" => "type.googleapis.com/google.rpc.ErrorInfo", "domain" => "a2a-protocol.org",
      "reason" => "TASK_NOT_CANCELABLE", "metadata" => {} } ] }
    response = ->(request, _) { native_response(request, error: error) }
    with_native(response: response) do
      body = rpc_native
      assert_equal error, body["error"]
      assert_equal "rejected", RelayDelivery.sole.phase
      assert_equal error, rpc_native["error"]
      assert_equal 0, Task.count
      assert_equal 1, @calls.size
    end
  end

  test "malformed files and colliding artifact IDs hold once without importing an invalid snapshot" do
    [ [ { "raw" => "%%%bad", "mediaType" => "application/octet-stream" } ],
      [ { "text" => "file", "filename" => 1 } ] ].each_with_index do |parts, index|
      response = ->(request, _) do
        snapshot = native_task(id: "invalid-task-#{index}", context: "invalid-context-#{index}")
        snapshot["artifacts"] = [ { "artifactId" => "file", "parts" => parts } ]
        native_response(request, result: { "task" => snapshot })
      end
      with_native(response: response) do
        body = rpc_native(message: user_message(id: "invalid-request-#{index}"))
        assert_equal "unconfirmed", body.dig("result", "task", "metadata", "concourse.delivery"), body.inspect
        assert_equal "held", body.dig("result", "task", "metadata", "concourse.route")
      end
    end
    response = ->(request, _) do
      snapshot = native_task(id: "duplicate-task", context: "duplicate-context")
      snapshot["artifacts"] = [ { "artifactId" => "same", "parts" => [ { "text" => "one" } ] },
        { "artifactId" => "same", "parts" => [ { "text" => "two" } ] } ]
      native_response(request, result: { "task" => snapshot })
    end
    with_native(response: response) do
      body = rpc_native(message: user_message(id: "duplicate-request"))
      assert_equal "unconfirmed", body.dig("result", "task", "metadata", "concourse.delivery")
    end
    assert_equal 0, RelayTask.count
    assert_equal 0, Artifact.count
    assert_equal 0, Task.inbox.count
    assert_equal 3, @calls.size
  end

  test "late verified response resolves an orphan hold under the original send fence, never another executor" do
    held_id = nil
    response = ->(request, _) do
      delivery = RelayDelivery.sole
      delivery.update!(deadline_at: 1.second.ago)
      A2a::Exchange.recover_delivery!(delivery)
      held = delivery.reload.task
      held_id = held.id
      assert held.held?
      assert_not held.actionable?
      native_response(request, result: { "task" => native_task })
    end
    with_native(response: response) do
      body = rpc_native
      assert_not body.key?("error"), body.inspect
      task = Task.find(body.dig("result", "task", "id"))
      assert_equal held_id, task.id
      assert task.native?
      assert_equal "accepted", task.relay_deliveries.sole.phase
      assert_equal task.id, rpc_native.dig("result", "task", "id")
      assert_equal 1, @calls.size
      assert_equal 0, Task.inbox.count
      assert_raises(Task::NotInbox) { task.ensure_inbox! }
      assert_not task.update(execution_route: "inbox")
    end
  end

  test "expired pending receipt neither locks registration nor participates in sweep recovery" do
    delivery = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, message: user_message,
      execution_route: "native", route_snapshot: NativeRelayTestSupport::ROUTE)
    delivery.expire!
    assert_not RelayDelivery.pending.exists?(delivery.id)
    assert_not @recipient.native_route_locked?
    RelaySweepJob.perform_now
    assert_equal 0, Task.count
    assert_nil delivery.reload.holder
  end

  test "context reuse refreshes content and active retained tasks protect their context mapping" do
    context = RelayContext.map!(caller: @caller, recipient: @recipient, generation: 1,
      public_context_id: "public-context", native_context_id: "native-context")
    context.update_columns(content_changed_at: 31.days.ago)
    reused = RelayContext.map!(caller: @caller, recipient: @recipient, generation: 1,
      public_context_id: "public-context", native_context_id: "native-context")
    assert_equal context.id, reused.id
    assert_operator reused.content_changed_at, :>, 1.minute.ago
    task = Task.create!(organization: @caller.organization, caller_agent: @caller, recipient_agent: @recipient,
      execution_route: "native", context_id: "public-context")
    context.update_columns(content_changed_at: 31.days.ago)
    PurgeExpiredTasksJob.perform_now
    assert RelayContext.exists?(context.id)
    assert Task.exists?(task.id)
  end
  test "ambiguous genuine continuation retains its existing immutable route without claiming progress" do
    response = ->(request, _) do
      if request.dig("params", "message", "taskId")
        raise A2a::NativeTransport::Unconfirmed.new(:timeout, phase: :http)
      end
      native_response(request, result: { "task" => native_task })
    end
    with_native(response: response) do
      body = rpc_native
      task = Task.find(body.dig("result", "task", "id"))
      task.update_columns(content_changed_at: 31.days.ago)
      state = task.state
      reply = rpc_native(message: user_message(id: "uncertain-input", task_id: task.id, context_id: task.context_id))
      assert_equal "RELAY_DELIVERY_UNCONFIRMED", reason(reply)
      assert_equal state, task.reload.state
      PurgeExpiredTasksJob.perform_now
      assert Task.exists?(task.id)
      assert_equal "native-task", task.reload.relay_task.native_task_id
      assert task.input_delivery_unconfirmed?
    end
  end

  test "crash recovery keeps original authored activity and content clock rather than renewing retention" do
    delivery = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, message: user_message,
      execution_route: "native", route_snapshot: NativeRelayTestSupport::ROUTE)
    delivery.start_sending!(holder: "lost-holder", deadline_at: 5.seconds.from_now)
    delivery.update!(created_at: 2.days.ago, content_changed_at: 2.days.ago, deadline_at: 1.second.ago)
    A2a::Exchange.recover_delivery!(delivery)
    task = delivery.reload.task
    assert task.held?
    assert_equal delivery.content_changed_at, task.content_changed_at
    assert_equal delivery.created_at, task.messages.sole.created_at
    assert_equal 0, Task.inbox.count
  end
end
