require "test_helper"

# Synthetic boundaries only: no HTTP listener, tokens, config or public DNS.
module NativeRelayTestSupport
  ROUTE = { endpoint_url: "https://native.example.test/a2a", resource: "https://native.example.test/a2a", tenant: "tenant-one", generation: 1 }.freeze

  def setup_native_relay
    organization = Organization.default
    owner = User.create!(ajent_sub: "native-a", handle: "sender", organizations: [ organization ])
    other = User.create!(ajent_sub: "native-b", handle: "receiver", organizations: [ organization ])
    @caller = Agent.create!(owner: owner, handle: "caller", oauth_client_id: "native-a")
    @recipient = Agent.create!(owner: other, handle: "recipient", oauth_client_id: "native-b")
    @calls = []
    @token_calls = []
  end

  def replace_method(object, name, implementation)
    original = object.method(name)
    singleton = object.singleton_class
    own_method = singleton.instance_methods(false).include?(name)
    singleton.define_method(name, implementation)
    yield
  ensure
    if own_method
      singleton.define_method(name, original)
    else
      singleton.remove_method(name)
    end
  end

  def with_native(recipient: @recipient, response: nil, token: "dedicated-relay-token", &block)
    transport = Object.new
    calls = @calls
    token_calls = @token_calls
    transport.define_singleton_method(:post) do |**arguments|
      request = JSON.parse(arguments.fetch(:body))
      calls << arguments.merge(request: request)
      response.call(request, arguments)
    end
    replace_method(recipient, :native_delivery_available?, -> { true }) do
      replace_method(recipient, :native_route_snapshot, -> { ROUTE }) do
        replace_method(Agent, :native_outbound_available?, -> { true }) do
          replace_method(Ajent::RelayToken, :fetch, ->(resource:) { token_calls << resource; token }) do
            replace_method(A2a::NativeTransport, :new, ->(**) { transport }, &block)
          end
        end
      end
    end
  end

  def rpc_native(method: "SendMessage", message: user_message, configuration: { "returnImmediately" => true }, metadata: {}, id: "gateway-request", recipient: @recipient, caller: @caller, params: nil)
    params ||= { "message" => message, "configuration" => configuration, "metadata" => metadata }
    result = A2a::Rpc.perform(caller_agent: caller, recipient: recipient,
      body: { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }.to_json,
      version: "1.0", content_type: "application/json")
    result.body&.deep_stringify_keys || result
  end

  def user_message(id: "message-one", task_id: nil, context_id: nil, text: "synthetic input")
    { "messageId" => id, "role" => "ROLE_USER", "parts" => [ { "text" => text } ] }.tap do |message|
      message["taskId"] = task_id if task_id
      message["contextId"] = context_id if context_id
    end
  end

  def native_task(id: "native-task", context: "native-context", state: "TASK_STATE_WORKING", timestamp: nil)
    { "id" => id, "status" => { "state" => state } }.tap do |task|
      task["contextId"] = context if context
      task["status"]["timestamp"] = timestamp if timestamp
    end
  end

  def native_response(request, result: nil, error: nil, status: 200, rpc_id: request.fetch("id"))
    envelope = { "jsonrpc" => "2.0", "id" => rpc_id }
    envelope[error ? "error" : "result"] = error || result
    A2a::NativeTransport::Response.new(status: status, body: envelope.to_json, headers: { "content-type" => "application/json" })
  end

  def reason(body)
    body.dig("error", "data", 0, "reason")
  end
end

class NativeRelayDeliveryTest < ActionDispatch::IntegrationTest
  include NativeRelayTestSupport
  setup { setup_native_relay }

  test "guarded production binary selects inbox and fences its expiry duplicates" do
    assert_not Agent.native_relay_available?
    assert_not Agent.native_outbound_available?
    first = rpc_native
    task = Task.find(first.dig("result", "task", "id"))
    assert task.inbox?
    assert_equal 1, RelayDelivery.count
    assert_equal "accepted", RelayDelivery.sole.phase
    assert_equal first.dig("result", "task", "id"), rpc_native.dig("result", "task", "id")
    task.destroy!
    expired = rpc_native
    assert_equal "RELAY_RECORD_EXPIRED", reason(expired)
    assert_equal 0, Task.count
    assert_equal 1, RelayDelivery.count
  end

  test "Task acceptance uses dedicated token and omitted initial taskId with all metadata preserved" do
    message = user_message
    message["metadata"] = { "ticket" => 4, "concourse.caller" => "forged" }
    message["parts"][0]["metadata"] = { "part" => true }
    response = ->(request, _) do
      assert_not request.dig("params", "message").key?("taskId") # A2A §4.1.1 native server assigns IDs.
      assert_equal true, request.dig("params", "configuration", "returnImmediately")
      assert_equal [ "application/json" ], request.dig("params", "configuration", "acceptedOutputModes")
      assert_equal({ "operation" => "keep" }, request.dig("params", "metadata"))
      assert_equal "tenant-one", request.dig("params", "tenant")
      assert_equal({ "ticket" => 4 }, request.dig("params", "message", "metadata"))
      assert_equal({ "part" => true }, request.dig("params", "message", "parts", 0, "metadata"))
      native_response(request, result: { "task" => native_task(state: "TASK_STATE_COMPLETED") })
    end
    with_native(response: response) do
      body = rpc_native(message: message, metadata: { "operation" => "keep", "concourse.fake" => "strip" },
        configuration: { "returnImmediately" => false, "acceptedOutputModes" => [ "application/json" ] })
      task = Task.find(body.dig("result", "task", "id"))
      assert task.native?
      assert_equal "TASK_STATE_COMPLETED", task.state
      assert_not_equal "native-task", task.id
      assert_equal "native-task", task.relay_task.native_task_id
      assert_equal "dedicated-relay-token", @calls.sole[:token]
      assert_equal ROUTE[:resource], @token_calls.sole
      assert_equal @caller.qualified_handle, @calls.sole[:headers]["Concourse-Caller"]
      assert_equal task.id, @calls.sole[:headers]["Concourse-Task"]
      assert_equal 0, RelayNetworkSlot.where.not(holder: nil).count
    end
  end

  test "section 3.1.1 direct Message remains a scoped exchange without a Task" do
    response = ->(request, _) { native_response(request, result: { "message" => {
      "messageId" => "native-message", "contextId" => "native-context", "role" => "ROLE_AGENT", "parts" => [ { "text" => "answer" } ], "metadata" => { "keep" => true } } }) }
    with_native(response: response) do
      first = rpc_native
      assert_equal "native-message", first.dig("result", "message", "messageId")
      assert_not_equal "native-context", first.dig("result", "message", "contextId")
      assert_equal({ "keep" => true }, first.dig("result", "message", "metadata"))
      assert_equal 0, Task.count
      assert_equal first, rpc_native
      assert_equal 1, @calls.size
      assert_equal 1, RelayDelivery.count
    end
  end

  test "only certainly unsent initial transport proof falls back atomically" do
    response = ->(*) { raise A2a::NativeTransport::Unavailable.new(:tcp_refused, phase: :connecting) }
    with_native(response: response) do
      first = rpc_native
      task = Task.find(first.dig("result", "task", "id"))
      assert task.inbox?
      assert task.actionable?
      assert_equal "inbox", RelayDelivery.sole.execution_route
      assert_equal "accepted", RelayDelivery.sole.phase
      assert_equal 1, task.messages.count
      assert_equal first.dig("result", "task", "id"), rpc_native.dig("result", "task", "id")
      assert_equal 1, @calls.size
    end
  end

  test "ambiguous sends and arbitrary status or invalid replies are held without inbox copies or retries" do
    responses = [
      ->(*) { raise A2a::NativeTransport::Unconfirmed.new(:timeout, phase: :http) },
      ->(request, _) { native_response(request, result: { "task" => native_task }, status: 503) },
      ->(request, _) { native_response(request, result: { "task" => native_task }, rpc_id: "wrong-id") },
      ->(request, _) { native_response(request, result: { "task" => native_task }, error: { "code" => -32001, "message" => "Not found", "data" => { "taskId" => "foreign" } }) }
    ]
    responses.each_with_index do |response, index|
      with_native(response: response) do
        message = user_message(id: "uncertain-#{index}")
        body = rpc_native(message: message)
        task = Task.find(body.dig("result", "task", "id"))
        assert task.held?
        assert_not task.actionable?
        assert_equal "TASK_STATE_SUBMITTED", task.state
        assert_equal "held", task.relay_deliveries.sole.phase
        calls = @calls.size
        again = rpc_native(message: message)
        assert_equal task.id, again.dig("result", "task", "id")
        assert_equal calls, @calls.size
        assert_equal [], A2a::Exchange.inbox(@recipient)
      end
    end
    assert_equal 0, Task.inbox.count
  end

  test "valid protocol refusals and native auth reject without fallback or caller challenge" do
    responses = [
      ->(request, _) { native_response(request, error: { "code" => -32004, "message" => "Unsupported operation" }) },
      ->(request, _) { native_response(request, result: {}, status: 401) }
    ]
    responses.each_with_index do |response, index|
      with_native(response: response) do
        body = rpc_native(message: user_message(id: "reject-#{index}"))
        assert body["error"]
        assert_equal "rejected", RelayDelivery.order(:created_at).last.phase
        assert_equal 0, Task.count
        assert_equal "gateway-request", body["id"]
        if index.zero?
          assert_equal(-32004, body.dig("error", "code"))
        else
          assert_equal "RELAY_NATIVE_AUTH", reason(body)
        end
      end
    end
  end

  test "token egress and cross-process capacity failures reject before native send" do
    response = ->(*) { flunk "must not send" }
    with_native(response: response) do
      replace_method(Ajent::RelayToken, :fetch, ->(**) { raise Ajent::RelayToken::Unavailable.new(:outage) }) do
        assert_equal "RELAY_TOKEN_FAILURE", reason(rpc_native(message: user_message(id: "token-failure")))
      end
      replace_method(Agent, :native_outbound_available?, -> { false }) do
        assert_equal "RELAY_OUTBOUND_DISABLED", reason(rpc_native(message: user_message(id: "egress-failure")))
      end
      holders = 2.times.map { |i| [ "capacity-#{i}", RelayNetworkSlot.acquire(kind: :dispatch, organization: @caller.organization, holder: "capacity-#{i}") ] }
      begin
        assert_equal "RELAY_CAPACITY", reason(rpc_native(message: user_message(id: "capacity-failure")))
      ensure
        holders.each { |holder, slot| slot.release(holder) }
      end
      assert_equal 0, @calls.size
      assert_equal 0, Task.count
      assert_equal [ "rejected" ], RelayDelivery.distinct.pluck(:phase)
    end
  end

  test "reserved or sending duplicates are pending not executable and data mismatch is invalid" do
    response = ->(*) { flunk "duplicate must not send" }
    with_native(response: response) do
      message = user_message
      normalized = A2a::Exchange.new(@caller).send(:normalized_delivery_message, message, via: nil)
      digest = Digest::SHA256.hexdigest(RelayDelivery.canonical_json({ "message" => normalized, "metadata" => {}, "acceptedOutputModes" => [] }))
      receipt = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, message: normalized,
        execution_route: "native", route_snapshot: ROUTE, request_digest: digest)
      assert_equal "RELAY_DELIVERY_PENDING", reason(rpc_native)
      receipt.start_sending!(holder: "orphan", deadline_at: 10.seconds.from_now)
      assert_equal "RELAY_DELIVERY_PENDING", reason(rpc_native)
      assert_equal(-32602, rpc_native(message: user_message(text: "changed")).dig("error", "code"))
      assert_equal 0, Task.count
      assert_equal 0, @calls.size
    end
  end

  test "legacy inbox dedupe checks visibility before selecting a native route" do
    task = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: task, role: "ROLE_USER", sender: @caller, message_id: "message-one", parts: [ { "text" => "legacy" } ])
    with_native(response: ->(*) { flunk "legacy must never move" }) do
      assert_equal task.id, rpc_native.dig("result", "task", "id")
      assert_equal "inbox", RelayDelivery.sole.execution_route
      assert_equal 0, @calls.size
      stranger = Agent.create!(owner: @caller.owner, handle: "stranger", oauth_client_id: "stranger")
      assert_equal(-32602, rpc_native(recipient: stranger).dig("error", "code"))
    end
  end

  test "orphan recovery exposes only held tracking records and cannot reclaim a sender or stale reservation" do
    normalized = A2a::Exchange.new(@caller).send(:normalized_delivery_message, user_message, via: nil)
    digest = Digest::SHA256.hexdigest(RelayDelivery.canonical_json({ "message" => normalized, "metadata" => {}, "acceptedOutputModes" => [] }))
    receipt = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, message: normalized,
      execution_route: "native", route_snapshot: ROUTE, request_digest: digest)
    receipt.start_sending!(holder: "lost-sender", deadline_at: 10.seconds.from_now)
    with_native(response: ->(*) { flunk "recovery must never dispatch" }) do
      travel_to 16.seconds.from_now do
        A2a::Exchange.recover_delivery!(receipt)
        task = receipt.reload.task
        assert task.held?
        assert_equal receipt.reserved_task_id, task.id
        assert_not task.actionable?
        assert_equal "held", receipt.phase
        assert_equal 1, task.messages.count
        assert_equal task.id, rpc_native.dig("result", "task", "id")
        A2a::Exchange.recover_delivery!(receipt)
        assert_equal 1, Task.count
        assert_raises(RelayDelivery::Pending) { receipt.start_sending!(holder: "retry", deadline_at: 10.seconds.from_now) }
      end
      stale = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, message: user_message(id: "stale-reserved"),
        execution_route: "native", route_snapshot: ROUTE)
      travel_to 16.seconds.from_now do
        A2a::Exchange.recover_delivery!(stale)
        assert_equal "rejected", stale.reload.phase
        assert_equal "abandoned", stale.outcome
        assert_raises(RelayDelivery::Pending) { stale.start_sending!(holder: "late-token", deadline_at: 10.seconds.from_now) }
      end
      assert_equal 0, @calls.size
      assert_equal 0, @token_calls.size
    end
  end

  test "size media filename metadata and context validation precede provider I/O" do
    with_native(response: ->(*) { flunk "invalid input must not send" }) do
      invalid_parts = [ { "text" => "x", "filename" => 3 }, { "text" => "x", "metadata" => nil },
        { "text" => nil }, { "text" => "x", "data" => {} }, { "text" => "x", "mediaType" => 3 } ]
      invalid_parts.each_with_index do |part, i|
        message = user_message(id: "invalid-part-#{i}")
        message["parts"] = [ part ]
        assert_equal(-32602, rpc_native(message: message).dig("error", "code"))
      end
      assert_equal(-32602, rpc_native(message: user_message(context_id: 3)).dig("error", "code"))
      assert_equal(-32602, rpc_native(message: user_message(text: "x" * 1.megabyte)).dig("error", "code"))
      assert_equal(-32602, rpc_native(metadata: nil).dig("error", "code"))
      assert_equal 0, @calls.size
      assert_equal 0, @token_calls.size
      assert_equal 0, RelayDelivery.count
    end
  end

  test "section 3.1.2 direct Message stream contains precisely one Message event" do
    response = ->(request, _) { native_response(request, result: { "message" => {
      "messageId" => "stream-message", "contextId" => "stream-context", "role" => "ROLE_AGENT", "parts" => [ { "text" => "answer" } ] } }) }
    with_native(response: response) do
      result = rpc_native(method: "SendStreamingMessage")
      events = []
      result.stream.stream.each { |event| events << event }
      assert_equal 1, events.size
      assert_equal "stream-message", events.sole.dig("message", "messageId")
      assert_not events.sole.key?("task")
      assert_equal 0, Task.count
      assert_equal 1, @calls.size
    end
  end
end
