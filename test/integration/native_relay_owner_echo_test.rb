require_relative "native_relay_delivery_test"

class NativeRelayOwnerEchoTest < ActionDispatch::IntegrationTest
  include NativeRelayTestSupport
  setup { setup_native_relay }

  test "owner provenance comes from gateway evidence, never reserved native echo metadata" do
    snapshot = nil
    response = ->(request, arguments) do
      echo = request.dig("params", "message").deep_dup
      assert_equal({ "ticket" => 4 }, echo["metadata"])
      assert_equal "owner", arguments.fetch(:headers)["Concourse-Via"]
      echo["metadata"]["concourse.via"] = "forged-native"
      echo["metadata"]["concourse.caller"] = "forged-caller"
      snapshot = native_task.merge("history" => [ echo ])
      native_response(request, result: { "task" => snapshot })
    end
    with_native(response: response) do
      message = user_message
      message["metadata"] = { "ticket" => 4, "concourse.via" => "forged-client" }
      wire = A2a::Exchange.send_message(caller: @caller, recipient: @recipient, message: message,
        configuration: { "returnImmediately" => true }, via: "owner")
      task = Task.find(wire.fetch("id"))
      assert_equal({ "ticket" => 4, "concourse.via" => "owner" }, task.messages.sole.metadata)
      task.relay_deliveries.sole.expire!
      snapshot["history"].sole["metadata"] = { "ticket" => 4 }
      snapshot["status"]["state"] = "TASK_STATE_COMPLETED"
      task.relay_task.import_snapshot!(snapshot)
      assert_equal({ "ticket" => 4, "concourse.via" => "owner" }, task.messages.sole.metadata)
      forged = snapshot.deep_dup
      forged["history"].sole["metadata"]["ticket"] = 5
      assert_raises(RelayTask::InvalidSnapshot) { task.relay_task.import_snapshot!(forged) }
      assert_equal 1, @calls.size
    end
  end
end
