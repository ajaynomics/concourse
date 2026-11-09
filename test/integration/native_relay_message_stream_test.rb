require_relative "native_relay_delivery_test"

class NativeRelayMessageStreamTest < ActiveSupport::TestCase
  include NativeRelayTestSupport
  setup { setup_native_relay }

  test "direct Message deferred streams recheck either participant without inventing a Task" do
    [ @caller, @recipient ].each_with_index do |removed, index|
      response = ->(request, _) { native_response(request, result: { "message" => {
        "messageId" => "creator-#{index}", "contextId" => "native-context-#{index}", "role" => "ROLE_AGENT",
        "parts" => [ { "text" => "synthetic response" } ] } }) }
      with_native(response: response) do
        stream = A2a::Exchange.send_streaming_message(caller: @caller, recipient: @recipient,
          message: user_message(id: "stream-#{index}"))
        membership = removed.owner.memberships.where(organization: removed.organization).sole
        membership.destroy!
        io = StringIO.new
        A2a::Rpc::EventStream.new(id: "public-rpc", stream: stream).call(io)
        assert_equal "", io.string
        assert io.closed?
        assert_equal 0, Task.count
        removed.owner.memberships.create!(organization: removed.organization)
      end
    end
  end

  test "expired direct receipt cannot disclose a retained deferred stream payload" do
    response = ->(request, _) { native_response(request, result: { "message" => {
      "messageId" => "creator", "contextId" => "native-context", "role" => "ROLE_AGENT",
      "parts" => [ { "text" => "synthetic response" } ] } }) }
    with_native(response: response) do
      stream = A2a::Exchange.send_streaming_message(caller: @caller, recipient: @recipient, message: user_message)
      RelayDelivery.sole.expire!
      io = StringIO.new
      A2a::Rpc::EventStream.new(id: "public-rpc", stream: stream).call(io)
      assert_equal "", io.string
      assert io.closed?
      assert_equal 0, Task.count
    end
  end
end
