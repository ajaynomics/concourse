require_relative "native_relay_delivery_test"

class NativeRelayIdMappingTest < ActionDispatch::IntegrationTest
  include NativeRelayTestSupport
  setup { setup_native_relay }

  test "native task ID collisions on different recipients remain distinct gateway identities" do
    second = Agent.create!(owner: @recipient.owner, handle: "second", oauth_client_id: "second")
    response = ->(request, _) { native_response(request, result: { "task" => native_task }) }
    with_native(response: response) do
      first = rpc_native.dig("result", "task", "id")
      with_native(recipient: second, response: response) do
        another = rpc_native(recipient: second, message: user_message(id: "second-send")).dig("result", "task", "id")
        assert first
        assert another
        assert_not_equal first, another
        assert_equal [ "native-task" ], RelayTask.distinct.pluck(:native_task_id)
        assert_equal 2, RelayTask.count
      end
    end
  end

  test "same parties native Task reuse returns its existing public mapping while another caller reuse holds" do
    response = ->(request, _) { native_response(request, result: { "task" => native_task }) }
    with_native(response: response) do
      first = rpc_native.dig("result", "task", "id")
      another = rpc_native(message: user_message(id: "another-initial"))
      assert_equal first, another.dig("result", "task", "id")
      assert_equal 1, Task.count
      assert_equal 1, RelayTask.count
      stranger = Agent.create!(owner: @caller.owner, handle: "stranger", oauth_client_id: "stranger")
      foreign = rpc_native(caller: stranger, message: user_message(id: "foreign-send"))
      held = Task.find(foreign.dig("result", "task", "id"))
      assert held.held?
      assert_not_equal first, held.id
      assert_nil held.relay_task
    end
  end

  test "Task context is optional and public task/context IDs never become initial native task IDs" do
    response = ->(request, _) { native_response(request, result: { "task" => native_task(context: nil) }) }
    with_native(response: response) do
      body = rpc_native
      task = Task.find(body.dig("result", "task", "id"))
      assert task.native?
      assert task.context_id.present?
      assert_nil task.relay_task.native_context_id
      assert_not @calls.sole[:request].dig("params", "message").key?("contextId")
      assert_not @calls.sole[:request].dig("params", "message").key?("taskId")
    end
  end

  test "reference IDs translate both ways through visible same-party same-route native mappings" do
    response = ->(request, _) do
      params = request.fetch("params")
      if @calls.size == 1
        native_response(request, result: { "task" => native_task })
      else
        assert_equal [ "native-task" ], params.dig("message", "referenceTaskIds")
        native_response(request, result: { "message" => {
          "messageId" => "native-reply", "contextId" => "another-context", "role" => "ROLE_AGENT",
          "parts" => [ { "data" => { "untouched" => "native-task" } } ], "referenceTaskIds" => [ "native-task" ] } })
      end
    end
    with_native(response: response) do
      first = rpc_native.dig("result", "task", "id")
      message = user_message(id: "reference-send")
      message["referenceTaskIds"] = [ first ]
      body = rpc_native(message: message)
      assert_equal [ first ], body.dig("result", "message", "referenceTaskIds")
      assert_equal "native-task", body.dig("result", "message", "parts", 0, "data", "untouched")
      message = user_message(id: "unmappable")
      inbox = Task.open!(caller: @caller, recipient: @recipient)
      message["referenceTaskIds"] = [ inbox.id ]
      calls = @calls.size
      assert_equal(-32602, rpc_native(message: message).dig("error", "code"))
      assert_equal calls, @calls.size
    end
  end

  test "initial Message cannot invent a task association or leak unknown native references" do
    response = ->(request, _) { native_response(request, result: { "message" => {
      "messageId" => "reply", "contextId" => "context", "taskId" => "foreign-native-task", "role" => "ROLE_AGENT", "parts" => [ { "text" => "answer" } ] } }) }
    with_native(response: response) do
      body = rpc_native
      task = Task.find(body.dig("result", "task", "id"))
      assert task.held?
      assert_not body.to_json.include?("foreign-native-task")
      assert_equal 0, RelayTask.count
    end
  end

  test "ROLE_USER echoes bind exact recorded requests and preserve creator IDs without adding caller activity" do
    response = ->(request, _) do
      task = native_task(state: "TASK_STATE_COMPLETED")
      echo = request.dig("params", "message").deep_dup
      echo["taskId"] = task["id"]
      echo["contextId"] = task["contextId"]
      task["history"] = [ echo, { "messageId" => "agent-wire-id", "role" => "ROLE_AGENT", "taskId" => task["id"], "contextId" => task["contextId"], "parts" => [ { "text" => "finished" } ] } ]
      native_response(request, result: { "task" => task })
    end
    with_native(response: response) do
      body = rpc_native
      task = Task.find(body.dig("result", "task", "id"))
      assert task.native?
      assert_equal 1, task.messages.where(role: "ROLE_USER").count
      assert_equal "message-one", body.dig("result", "task", "history", 0, "messageId")
      assert_equal "agent-wire-id", body.dig("result", "task", "history", 1, "messageId")
      assert_equal [ task.id ], body.dig("result", "task", "history").map { |m| m["taskId"] }.uniq
      assert_equal [ task.context_id ], body.dig("result", "task", "history").map { |m| m["contextId"] }.uniq
    end
  end
end
