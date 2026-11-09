require_relative "native_relay_delivery_test"

class NativeRelayCancelTest < ActionDispatch::IntegrationTest
  include NativeRelayTestSupport
  setup { setup_native_relay }

  def task_response(request, state: "TASK_STATE_WORKING")
    task = native_task(state: state)
    native_response(request, result: request["method"] == "CancelTask" ? task : { "task" => task })
  end

  def cancel(id)
    rpc_native(method: "CancelTask", params: { "id" => id })
  end

  test "CancelTask uses only stored native identity and reports only the evidenced native state" do
    response = ->(request, arguments) do
      if request["method"] == "CancelTask"
        assert_equal "native-task", request.dig("params", "id")
        assert_equal ROUTE[:endpoint_url], arguments[:url]
        task_response(request, state: "TASK_STATE_CANCELED")
      else
        task_response(request)
      end
    end
    with_native(response: response) do
      id = rpc_native.dig("result", "task", "id")
      replace_method(@recipient, :native_delivery_available?, -> { false }) do
        body = cancel(id)
        assert_equal id, body.dig("result", "id")
        assert_equal "TASK_STATE_CANCELED", body.dig("result", "status", "state")
        assert_equal "accepted", RelayDelivery.where(operation: "CancelTask").sole.phase
      end
      assert_equal 2, @calls.size
      assert_equal 0, RelayNetworkSlot.where.not(holder: nil).count
    end
  end

  test "cancel timeouts preserve native state and record uncertainty, never local CANCELED" do
    response = ->(request, _) do
      raise A2a::NativeTransport::Unconfirmed.new(:timeout, phase: :http) if request["method"] == "CancelTask"
      task_response(request)
    end
    with_native(response: response) do
      id = rpc_native.dig("result", "task", "id")
      body = cancel(id)
      assert_equal "RELAY_DELIVERY_UNCONFIRMED", reason(body)
      assert_equal "TASK_STATE_WORKING", Task.find(id).state
      assert_equal "held", RelayDelivery.where(operation: "CancelTask").sole.phase
      assert_equal 0, Task.inbox.count
      assert_equal 0, RelayNetworkSlot.where.not(holder: nil).count
    end
  end

  test "held initial send without upstream task identity is not cancelable" do
    with_native(response: ->(*) { raise A2a::NativeTransport::Unconfirmed.new(:timeout, phase: :http) }) do
      id = rpc_native.dig("result", "task", "id")
      assert_equal(-32002, cancel(id).dig("error", "code"))
      assert_equal 1, @calls.size
      assert_equal "TASK_STATE_SUBMITTED", Task.find(id).state
    end
  end

  test "held input blocks further input but permits explicit evidenced upstream cancel" do
    response = ->(request, _) do
      if request["method"] == "CancelTask"
        task_response(request, state: "TASK_STATE_CANCELED")
      elsif @calls.size > 1
        raise A2a::NativeTransport::Unconfirmed.new(:timeout, phase: :http)
      else
        task_response(request, state: "TASK_STATE_INPUT_REQUIRED")
      end
    end
    with_native(response: response) do
      id = rpc_native.dig("result", "task", "id")
      input = rpc_native(message: user_message(id: "input", task_id: id))
      assert_equal "RELAY_DELIVERY_UNCONFIRMED", reason(input)
      assert_equal "TASK_STATE_INPUT_REQUIRED", Task.find(id).state
      assert_equal "RELAY_MUTATION_BUSY", reason(rpc_native(message: user_message(id: "next-input", task_id: id)))
      assert_equal "TASK_STATE_CANCELED", cancel(id).dig("result", "status", "state")
      assert_equal "held", RelayDelivery.where(operation: "SendMessage", phase: "held").sole.phase
      assert_equal 3, @calls.size
    end
  end

  test "mutation fences out a long observation while pending send excludes simultaneous cancel" do
    response = ->(request, _) { task_response(request) }
    with_native(response: response) do
      id = rpc_native.dig("result", "task", "id")
      mapping = Task.find(id).relay_task
      assert mapping.acquire_observation!(holder: "follower")
      observed_fence = mapping.fence
      assert_equal id, cancel(id).dig("result", "id")
      assert_nil mapping.reload.lease_holder
      assert_operator mapping.fence, :>, observed_fence
      assert_raises(RelayTask::LostLease) do
        mapping.observe_native_event!(payload: { "task" => native_task }, holder: "follower", fence: observed_fence)
      end
      assert_not rpc_native(message: user_message(id: "during-follow", task_id: id)).key?("error")
      mapping.finish_observation!(holder: "follower", fence: observed_fence)
      task = Task.find(id)
      pending = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, task: task,
        message: user_message(id: "pending-input", task_id: id), execution_route: "native", route_snapshot: mapping.route_snapshot)
      assert_equal "reserved", pending.phase
      assert_not mapping.acquire_observation!(holder: "later-follower")
      assert_equal "RELAY_MUTATION_BUSY", reason(cancel(id))
      assert_equal 3, @calls.size
    end
  end

  test "native refusal of cancel stays a refusal and deliberate repeated cancels never infer status" do
    response = ->(request, _) do
      request["method"] == "CancelTask" ? native_response(request, error: { "code" => -32002, "message" => "Task not cancelable" }) : task_response(request)
    end
    with_native(response: response) do
      id = rpc_native.dig("result", "task", "id")
      2.times { assert_equal(-32002, cancel(id).dig("error", "code")) } # A2A §3.3.1 permits deliberate repeats.
      assert_equal "TASK_STATE_WORKING", Task.find(id).state
      assert_equal 2, RelayDelivery.where(operation: "CancelTask", phase: "rejected").count
      assert_equal 3, @calls.size
    end
  end
end
