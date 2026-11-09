require "test_helper"

class A2aNativeResultTest < ActiveSupport::TestCase
  test "section 3.1.1 response is a task or direct Message, not an unwrapped SDK union" do
    task = { "id" => "native", "status" => { "state" => "TASK_STATE_SUBMITTED" } }
    parsed = parse("task" => task)
    assert_equal task, parsed.task
    assert_nil parsed.message
    message = { "messageId" => "m", "contextId" => "c", "role" => "ROLE_AGENT", "parts" => [ { "text" => "answer" } ] }
    assert_equal message, parse("message" => message).message
    assert_raises(A2a::NativeResult::Invalid) { parse(task) }
    assert_raises(A2a::NativeResult::Invalid) { parse("task" => task, "message" => message) }
  end

  test "matching rpc identity and single envelope branch required" do
    assert_raises(A2a::NativeResult::Invalid) { A2a::NativeResult.parse('{"jsonrpc":"2.0","id":"foreign","result":{}}', rpc_id: "request") }
    assert_raises(A2a::NativeResult::Invalid) { A2a::NativeResult.parse('{"jsonrpc":"2.0","id":"request","result":{},"error":{}}', rpc_id: "request") }
    assert_raises(A2a::NativeResult::Invalid) { A2a::NativeResult.parse("x" * (2.megabytes + 1), rpc_id: "request") }
  end

  test "section 4.1.1 task context may be absent but section 4.1.4 Message context is required" do
    assert parse("task" => { "id" => "t", "status" => { "state" => "TASK_STATE_COMPLETED" } }).task
    assert_raises(A2a::NativeResult::Invalid) { parse("message" => { "messageId" => "m", "role" => "ROLE_AGENT", "parts" => [ { "text" => "x" } ] }) }
  end

  test "task associations and role/state enums validated without coercion" do
    message = { "messageId" => "m", "contextId" => "c", "taskId" => "another", "role" => "ROLE_USER", "parts" => [ { "text" => "echo" } ] }
    task = { "id" => "t", "contextId" => "c", "status" => { "state" => "TASK_STATE_WORKING" }, "history" => [ message ] }
    assert_raises(A2a::NativeResult::Invalid) { parse("task" => task) }
    task["history"] = []
    task["status"]["state"] = "working"
    assert_raises(A2a::NativeResult::Invalid) { parse("task" => task) }
  end

  test "section 5.6 metadata extensions and file output are preserved, never fetched" do
    artifact = { "artifactId" => "wire-id", "metadata" => { "x" => 1 }, "extensions" => [ "urn:x" ], "parts" => [ { "url" => "https://unfetched.invalid/file", "mediaType" => "application/pdf", "metadata" => { "part" => true } } ] }
    task = { "id" => "t", "status" => { "state" => "TASK_STATE_COMPLETED" }, "metadata" => { "upstream" => true }, "artifacts" => [ artifact ] }
    assert_equal task, parse("task" => task).task
    task["artifacts"][0]["parts"][0]["text"] = "ambiguous union"
    assert_raises(A2a::NativeResult::Invalid) { parse("task" => task) }
  end

  test "unknown ID-bearing error details fail closed before they can leak" do
    envelope = { "jsonrpc" => "2.0", "id" => "request", "error" => { "code" => -32001, "message" => "Task not found" } }
    assert_equal envelope["error"], A2a::NativeResult.parse(envelope.to_json, rpc_id: "request").error
    envelope["error"]["data"] = { "taskId" => "secret-upstream-id" }
    assert_raises(A2a::NativeResult::Invalid) { A2a::NativeResult.parse(envelope.to_json, rpc_id: "request") }
  end

  test "both JSON-RPC result paths reject binary invalid UTF8 in Text metadata and errors before import" do
    task = { "id" => "t", "status" => { "state" => "TASK_STATE_WORKING" } }
    text_task = task.merge("artifacts" => [ { "artifactId" => "wire", "parts" => [ { "text" => "private-body" } ] } ])
    metadata_task = task.merge("metadata" => { "nested" => { "provider" => "private-body" } })
    %i[parse parse_task].each do |method|
      [ text_task, metadata_task, nil ].each do |snapshot|
        envelope = { "jsonrpc" => "2.0", "id" => "request" }
        if snapshot
          envelope["result"] = method == :parse ? { "task" => snapshot } : snapshot
        else
          envelope["error"] = { "code" => -32001, "message" => "private-body" }
        end
        body = envelope.to_json.b.sub("private-body", "private-body\xff".b).freeze
        original = body.dup
        error = assert_raises(A2a::NativeResult::Invalid) { A2a::NativeResult.public_send(method, body, rpc_id: "request") }
        assert_equal "A2a::NativeResult::Invalid", error.message
        assert_nil error.cause
        assert_not_includes error.message, "private-body"
        assert_equal original, body
        assert_equal Encoding::BINARY, body.encoding
      end
    end
  end

  test "both JSON-RPC result paths accept binary valid UTF8 without mutating the provider body" do
    task = { "id" => "t", "status" => { "state" => "TASK_STATE_WORKING" },
      "metadata" => { "provider" => "café" }, "artifacts" => [ { "artifactId" => "wire", "parts" => [ { "text" => "café" } ] } ] }
    %i[parse parse_task].each do |method|
      result = method == :parse ? { "task" => task } : task
      body = { "jsonrpc" => "2.0", "id" => "request", "result" => result }.to_json.b.freeze
      original = body.dup
      assert_equal task, A2a::NativeResult.public_send(method, body, rpc_id: "request").task
      assert_equal original, body
      assert_equal Encoding::BINARY, body.encoding
    end
  end

  test "relay wait limit ErrorInfo contains public IDs only and is not a login challenge" do
    error = A2a::RelayError.new("RELAY_WAIT_LIMIT", task_id: "public", delivery_id: "receipt")
    assert_equal(-32603, error.code)
    assert_equal "concourse.example.com", error.data.first["domain"]
    assert_equal "RELAY_WAIT_LIMIT", error.data.first["reason"]
    assert_equal({ "taskId" => "public", "deliveryId" => "receipt" }, error.data.first["metadata"])
  end

  private

  def parse(result)
    A2a::NativeResult.parse({ "jsonrpc" => "2.0", "id" => "request", "result" => result }.to_json, rpc_id: "request")
  end
end
