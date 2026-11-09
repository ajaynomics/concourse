require_relative "native_relay_delivery_test"

class NativeRelayRoundTripTest < ActionDispatch::IntegrationTest
  include NativeRelayTestSupport
  setup { setup_native_relay }

  test "input and completion stay on the immutable native mapping after a selection switch change" do
    response = ->(request, arguments) do
      if @calls.size == 1
        native_response(request, result: { "task" => native_task(state: "TASK_STATE_INPUT_REQUIRED", timestamp: "2026-10-07T12:00:00Z") })
      else
        assert_equal "native-task", request.dig("params", "message", "taskId")
        assert_equal "native-context", request.dig("params", "message", "contextId")
        assert_equal ROUTE[:endpoint_url], arguments[:url]
        native_response(request, result: { "task" => native_task(state: "TASK_STATE_COMPLETED", timestamp: "2026-10-07T12:01:00Z") })
      end
    end
    with_native(response: response) do
      initial = rpc_native(configuration: {})
      id = initial.dig("result", "task", "id")
      context = initial.dig("result", "task", "contextId")
      assert_equal "TASK_STATE_INPUT_REQUIRED", initial.dig("result", "task", "status", "state")
      replace_method(@recipient, :native_delivery_available?, -> { false }) do
        replace_method(@recipient, :native_route_snapshot, -> { flunk "must not reselect" }) do
          # This case proves route immutability, not a 200ms scheduling deadline;
          # dispatch-budget exhaustion is exercised independently below.
          A2a::Exchange.with_limits(blocking: 2) do
            complete = rpc_native(message: user_message(id: "input", task_id: id, context_id: context), configuration: {})
            assert_equal id, complete.dig("result", "task", "id"), complete.inspect
            assert_equal "TASK_STATE_COMPLETED", complete.dig("result", "task", "status", "state")
          end
        end
      end
      assert_equal 1, Task.count
      assert_equal 2, RelayDelivery.count
      assert_equal 0, Task.inbox.count
      assert Task.find(id).relay_task.next_follow_at
    end
  end

  test "unchanged INPUT_REQUIRED does not settle new input even when user echo changes history" do
    response = ->(request, _) do
      task = native_task(state: "TASK_STATE_INPUT_REQUIRED", timestamp: "2026-10-07T12:00:00Z")
      if @calls.size > 1
        echo = request.dig("params", "message").deep_dup
        task["history"] = [ echo ]
      end
      native_response(request, result: { "task" => task })
    end
    with_native(response: response) do
      id = rpc_native.dig("result", "task", "id")
      A2a::Exchange.with_limits(blocking: 0.05, poll: 0.01) do
        body = rpc_native(message: user_message(id: "input", task_id: id), configuration: {})
        assert_equal "RELAY_WAIT_LIMIT", reason(body)
        assert_equal id, body.dig("error", "data", 0, "metadata", "taskId")
      end
      assert_equal "TASK_STATE_INPUT_REQUIRED", Task.find(id).state
      assert_equal "accepted", RelayDelivery.order(:created_at).last.phase
      assert_equal 2, @calls.size
    end
  end

  test "blocking budget includes dispatch and waiter saturation errors never cancel accepted work" do
    response = ->(request, _) do
      sleep 0.03
      native_response(request, result: { "task" => native_task })
    end
    with_native(response: response) do
      A2a::Exchange.with_limits(blocking: 0.01) do
        # Dispatch exhausts the cap: no waiter may be borrowed (§3.2.2), regardless of host scheduling.
        replace_method(A2a::Waiters, :acquire, ->(*) { raise Minitest::Assertion, "expired dispatch must not acquire a waiter" }) do
          body = rpc_native(configuration: {})
          assert_equal "RELAY_WAIT_LIMIT", reason(body)
          assert_equal 1, @calls.size
        end
      end
      replace_method(A2a::Waiters, :acquire, ->(*) { false }) do
        body = rpc_native(message: user_message(id: "another-initial"), configuration: {})
        assert_equal "RELAY_WAIT_LIMIT", reason(body)
      end
      assert_equal "TASK_STATE_WORKING", Task.sole.state
      assert_equal 0, RelayDelivery.where(operation: "CancelTask").count
      assert_equal 0, Task.inbox.count
    end
  end

  test "accepted receipt replay uses scoped current Task result without further I/O" do
    response = ->(request, _) { native_response(request, result: { "task" => native_task }) }
    with_native(response: response) do
      id = rpc_native.dig("result", "task", "id")
      Task.find(id).relay_task.import_snapshot!(native_task(state: "TASK_STATE_COMPLETED"))
      body = rpc_native(configuration: { "returnImmediately" => false, "historyLength" => 0 })
      assert_equal id, body.dig("result", "task", "id")
      assert_equal "TASK_STATE_COMPLETED", body.dig("result", "task", "status", "state")
      assert_not body.dig("result", "task").key?("history")
      assert_equal 1, @calls.size
    end
  end

  test "certain non-delivery of continuation never opens an inbox executor" do
    response = ->(request, _) do
      raise A2a::NativeTransport::Unavailable.new(:tcp_refused, phase: :connecting) if @calls.size > 1
      native_response(request, result: { "task" => native_task(state: "TASK_STATE_INPUT_REQUIRED") })
    end
    with_native(response: response) do
      id = rpc_native.dig("result", "task", "id")
      body = rpc_native(message: user_message(id: "input", task_id: id))
      assert_equal "RELAY_DELIVERY_UNCONFIRMED", reason(body)
      assert_equal "native", Task.find(id).execution_route
      assert_equal "TASK_STATE_INPUT_REQUIRED", Task.find(id).state
      assert_equal 0, Task.inbox.count
      assert_equal "held", RelayDelivery.where(phase: "held").sole.phase
    end
  end

  test "native worker writes are rejected before adding a partial message and trusted owner attribution is sent upfront" do
    response = ->(request, arguments) do
      if @calls.size > 1
        assert_equal "owner", arguments.fetch(:headers)["Concourse-Via"]
        assert_nil request.dig("params", "message", "metadata", "concourse.via")
      end
      native_response(request, result: { "task" => native_task(state: "TASK_STATE_INPUT_REQUIRED") })
    end
    with_native(response: response) do
      id = rpc_native.dig("result", "task", "id")
      assert_raises(A2a::Error) { A2a::Exchange.reply(agent: @recipient, task_id: id, parts: [ { "text" => "invalid worker reply" } ]) }
      assert_equal 1, Task.find(id).messages.count
      A2a::Exchange.send_message(caller: @caller, recipient: @recipient, message: user_message(id: "owner-input", task_id: id), configuration: { "returnImmediately" => true }, via: "owner")
      assert_equal 2, @calls.size
    end
  end

  test "participant removal while send is in flight exposes no result or fallback body" do
    response = ->(request, _) do
      @recipient.owner.memberships.where(organization: @recipient.organization).delete_all
      native_response(request, result: { "task" => native_task })
    end
    with_native(response: response) do
      body = rpc_native
      assert_equal(-32001, body.dig("error", "code"))
      assert_equal 0, Task.count
      assert_nil RelayDelivery.sole.request_payload
      assert RelayDelivery.sole.expired_at
      assert_equal 0, RelayNetworkSlot.where.not(holder: nil).count
    end
  end
end
