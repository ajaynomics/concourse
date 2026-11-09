require "test_helper"
require_relative "native_relay_delivery_test"

# Synthetic native MCP/Exchange results only. A2A §3.3.1 dedupe is not a
# cross-operation replay promise; §3.1.1 Message answers never invent a Task.
class NativeSendReceiptTest < ActionDispatch::IntegrationTest
  include NativeRelayTestSupport

  setup do
    @release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    setup_native_relay
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @release
  end

  test "native MCP call serializes the exact persisted wire pair in text and structured result" do
    stub_agent_token("receipt-mcp", client_id: @caller.oauth_client_id, sub: @caller.owner.ajent_sub,
      resource: :mcp, organization: @caller.organization)
    post "/mcp", params: { jsonrpc: "2.0", id: "receipt", method: "tools/call", params: { name: "send_message",
      arguments: { to: @recipient.qualified_handle, text: "synthetic receipt" } } }.to_json,
      headers: { "Authorization" => "Bearer receipt-mcp", "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
    assert_response :ok
    result = response.parsed_body.fetch("result")
    assert_not result["isError"]
    body = result.fetch("structuredContent")
    assert_equal body, JSON.parse(result.fetch("content").first.fetch("text"))
    SendMessageTool.output_schema.validate_result(body)
    delivery = RelayDelivery.sole
    message = delivery.task.messages.sole
    assert_not_equal message.message_id, message.wire_message_id
    assert_equal message.message_id, delivery.result_payload.fetch("callerInputMessageId")
    assert_equal receipt_for(message), receipt(body)
    assert_equal receipt(body), delivery.result_payload.fetch("sendReceipt")
    assert_equal @caller.id, body.dig("metadata", "concourse.participants", "caller", "agentId")
    assert_nil receipt(A2a::Exchange.get_task(viewer: @caller, id: body.fetch("id")))
  end

  test "later input at the serialization seam cannot replace this send operation identity" do
    original = A2a::Serializer.method(:task)
    later = nil
    entered = false
    send_later = method(:send_input)
    replacement = ->(record, **options) do
      unless entered
        entered = true
        # Deterministic interleaving: delivery already committed; the original
        # serialization has not read latest_caller_input. No timing/sleep race.
        later = send_later.call("later", task_id: record.id)
      end
      original.call(record, **options)
    end
    first = nil
    freeze_time do
      replace_method(A2a::Serializer, :task, replacement) { first = send_input("first") }
    end
    assert_equal "first", receipt(first).dig("callerInput", "messageId")
    assert_equal "later", first.dig("metadata", "concourse.caller_input", "messageId")
    assert_equal receipt(later).fetch("callerInput"), first.dig("metadata", "concourse.caller_input")
    assert_not_equal receipt(first), receipt(later)
    assert_equal receipt(first), RelayDelivery.find_by!(message_id_digest: Digest::SHA256.hexdigest("first")).result_payload.fetch("sendReceipt")
  end

  test "new Exchange dedupe after later input preserves original pair and original body semantics" do
    first = send_input("original")
    send_input("later", task_id: first.fetch("id"))
    replayed = send_input("original", text: "changed body ignored on inbox")
    assert_equal receipt(first), receipt(replayed)
    assert_equal "later", replayed.dig("metadata", "concourse.caller_input", "messageId")
    assert_equal 2, Message.count
    assert_equal 2, RelayDelivery.count
    # The returned object is not the persisted acceptance payload.
    receipt(first)["callerInput"]["messageId"] = "mutated"
    assert_equal "original", receipt(send_input("original")).dig("callerInput", "messageId")
  end

  test "fenced reply correlation still uses the immutable sent pair" do
    first = send_input("original")
    pair = receipt(first).fetch("callerInput")
    replied = A2a::Exchange.reply(agent: @recipient, task_id: first.fetch("id"), expected_caller_input: pair,
      parts: [ { "text" => "answer" } ], state: "TASK_STATE_WORKING")
    send_input("later", task_id: replied.id)
    body = A2a::Serializer.task(replied.reload)
    assert_equal pair, body.dig("status", "message", "metadata", "concourse.reply_to", "callerInput")
    assert_nil receipt(body)
  end

  test "malformed mismatched or absent persisted evidence fails closed without backfill" do
    first = send_input("original")
    send_input("later", task_id: first.fetch("id"))
    delivery = RelayDelivery.find_by!(message_id_digest: Digest::SHA256.hexdigest("original"))
    valid = delivery.result_payload.deep_dup
    invalid = [ nil, {}, { "version" => 2, "callerInput" => valid.dig("sendReceipt", "callerInput") },
      { "version" => 1.0, "callerInput" => valid.dig("sendReceipt", "callerInput") } ]
    [ "0", "01", "-1", "1.0", "1\n", 1, nil ].each do |cursor|
      invalid << { "version" => 1, "callerInput" => { "cursor" => cursor, "messageId" => "original" } }
    end
    invalid << { "version" => 1, "callerInput" => valid.dig("sendReceipt", "callerInput").merge("messageId" => "later") }
    invalid << valid.fetch("sendReceipt").merge("extra" => true)
    invalid.each do |value|
      payload = valid.merge("sendReceipt" => value)
      delivery.update_columns(result_payload: payload)
      assert_nil receipt(send_input("original")), value.inspect
      assert_equal payload, delivery.reload.result_payload, "read must not backfill"
    end
    [ { "callerInputMessageId" => "missing" }, { "callerInputMessageId" => Task.find(first.fetch("id")).messages.find_by!(client_message_id: "later").message_id },
      { "task" => { "id" => "other-task" } } ].each do |change|
      delivery.update_columns(result_payload: valid.merge(change))
      assert_nil receipt(send_input("original"))
    end
    assert_equal 2, Message.count
  end

  test "missing and duplicate exact Message events never select latest or first evidence" do
    body = send_input("original")
    task = Task.find(body.fetch("id"))
    message = task.messages.sole
    event = task.events.find(receipt(body).dig("callerInput", "cursor"))
    task.events.create!(kind: "caller_input", payload: event.payload, created_at: event.created_at)
    assert_nil receipt(send_input("original"))
    task.events.where(kind: "caller_input").delete_all
    assert_nil receipt(send_input("original"))
    assert_equal message.message_id, RelayDelivery.sole.result_payload.fetch("callerInputMessageId")
  end

  test "legacy reference snapshot and pre-receipt Message results never gain send receipts" do
    first = send_input("original")
    delivery = RelayDelivery.sole
    [ { "task" => { "id" => first.fetch("id") } }, { "task" => first } ].each do |payload|
      delivery.update_columns(result_payload: payload)
      assert_nil receipt(send_input("original"))
      assert_equal payload, delivery.reload.result_payload
    end
    task = Task.find(first.fetch("id"))
    task.with_lock { Message.record!(task: task, role: "ROLE_USER", sender: @caller, message_id: "legacy", parts: [ { "text" => "legacy" } ]) }
    assert_nil receipt(send_input("legacy"))
    assert_equal 2, Message.count
  end

  test "settled payload cannot be rewritten and expired acceptance cannot be replayed" do
    send_input("original")
    delivery = RelayDelivery.sole
    assert_not delivery.update(result_payload: { "task" => { "id" => delivery.task_id } })
    delivery.reload.expire!
    assert_nil delivery.result_payload
    error = assert_raises(A2a::RelayError) { send_input("original") }
    assert_equal "RELAY_RECORD_EXPIRED", error.data.first.fetch("reason")
    assert_equal 1, Message.count
  end

  test "user metadata cannot forge operation evidence in Task Message or Artifact output" do
    forged = { "version" => 1, "callerInput" => { "cursor" => "999", "messageId" => "forged" } }
    body = send_input("original", metadata: { "concourse.send_receipt" => forged })
    assert_equal "original", receipt(body).dig("callerInput", "messageId")
    task = Task.find(body.fetch("id"))
    assert_nil task.messages.sole.metadata["concourse.send_receipt"]
    message = Message.record!(task: task, role: "ROLE_AGENT", sender: @recipient,
      parts: [ { "text" => "stored" } ], metadata: { "concourse.send_receipt" => forged })
    artifact = Artifact.record!(task: task, by: @recipient, parts: [ { "text" => "stored" } ], metadata: { "concourse.send_receipt" => forged })
    assert_nil receipt(A2a::Serializer.message(message))
    assert_nil receipt(A2a::Serializer.artifact(artifact))
  end

  test "legacy release output stays unasserted" do
    Rails.application.config.x.concourse.release_line = 2
    assert_nil receipt(send_input("legacy-release"))
    assert_not RelayDelivery.sole.result_payload.key?("sendReceipt")
  end

  test "direct Message and protocol error paths do not fabricate a Task receipt" do
    network = A2a::Network.ensure!(@caller.organization)
    direct = A2a::Exchange.send_message(caller: @caller, recipient: network, configuration: { "returnImmediately" => true },
      message: { "messageId" => "presence", "role" => "ROLE_USER", "parts" => [ { "mediaType" => "application/json",
        "data" => { "operation" => "presence", "agent" => @recipient.qualified_handle } } ] })
    assert_kind_of A2a::DirectMessage, direct
    assert_nil receipt(ConcourseMcp.result(direct).structured_content)
    assert_nil receipt(A2a::Exchange.send_message(caller: @caller, recipient: network, configuration: { "returnImmediately" => true },
      message: { "messageId" => "presence", "role" => "ROLE_USER", "parts" => [ { "text" => "dedupe" } ] }).to_h)
    assert_equal 0, Task.count
    failed = SendMessageTool.call(server_context: ConcourseMcp::Context.new(agent: @caller), to: "missing/recipient", text: "x")
    assert failed.error?
    assert_nil receipt(failed.structured_content)
  end

  test "synthetic native accepted held refused and direct paths have no inbox receipt" do
    responses = [
      ->(request, _) { native_response(request, result: { "task" => native_task }) },
      ->(*) { raise A2a::NativeTransport::Unconfirmed.new(:timeout, phase: :http) },
      ->(request, _) { native_response(request, error: { "code" => -32004, "message" => "Unsupported operation" }) },
      ->(request, _) { native_response(request, result: { "message" => { "messageId" => "native-direct", "role" => "ROLE_AGENT",
        "contextId" => "native-context", "parts" => [ { "text" => "direct" } ], "metadata" => { "concourse.send_receipt" => {} } } }) }
    ]
    responses.each_with_index do |response, index|
      with_native(response: response) do
        body = rpc_native(message: user_message(id: "boundary-#{index}"))
        assert_nil body.dig("result", "task", "metadata", "concourse.send_receipt")
        assert_nil body.dig("result", "message", "metadata", "concourse.send_receipt")
        assert_equal(-32004, body.dig("error", "code")) if index == 2
        calls = @calls.size
        assert_equal body, rpc_native(message: user_message(id: "boundary-#{index}"))
        assert_equal calls, @calls.size
      end
    end
  end

  private

  def send_input(id, task_id: nil, text: "synthetic input", metadata: {})
    message = user_message(id: id, task_id: task_id, text: text).merge("metadata" => metadata)
    A2a::Exchange.new(@caller).send_message(@recipient, message, { "returnImmediately" => true })
  end

  def receipt(body)
    body.dig("metadata", "concourse.send_receipt")
  end

  def receipt_for(message)
    { "version" => 1, "callerInput" => message.recorded_caller_input }
  end
end
