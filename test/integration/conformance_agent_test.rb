require "test_helper"

class ConformanceAgentTest < ActionDispatch::IntegrationTest
  setup do
    @previous_handler = A2a::Inbound.handler
    A2a::Inbound.handler = A2a::Conformance.method(:deliver)
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @caller = Agent.create!(owner: @owner, handle: "codex", oauth_client_id: "client-a")
    @agent = A2a::Conformance.ensure!
    with_memory_cache { stub_agent_token("token-a", client_id: "client-a", sub: "42") }
  end

  teardown do
    A2a::Inbound.handler = @previous_handler
  end

  test "ensure is idempotent and the public card declares the TCK fields" do
    again = A2a::Conformance.ensure!
    assert_equal @agent.id, again.id
    assert_equal "concourse", @agent.owner.handle
    assert_nil @agent.owner.ajent_sub
    assert @agent.organization.platform?, "the conformance agent lives in the platform's organization"

    get "/a2a/concourse/conformance/.well-known/agent-card.json"
    assert_response :success
    card = response.parsed_body
    assert_equal A2a::Card::MODES, card["defaultInputModes"]
    assert_equal A2a::Card::MODES, card["defaultOutputModes"]
    assert_equal "JSONRPC", card.dig("supportedInterfaces", 0, "protocolBinding")
    assert_equal "1.0", card.dig("supportedInterfaces", 0, "protocolVersion")
    assert_equal true, card.dig("capabilities", "streaming")
    assert_equal false, card.dig("capabilities", "pushNotifications")
    assert_equal "tck", card.dig("skills", 0, "id")
    assert card["securitySchemes"].present?
  end

  test "messageId prefixes settle in both execution modes" do
    with_memory_cache do
      completed = send_to("tck-complete-task-1", "ignored", configuration: {})
      assert_equal "TASK_STATE_COMPLETED", state_of(completed)
      assert_equal "Hello from TCK", status_text(completed)

      immediate = send_to("tck-complete-task-2", "ignored", configuration: { "returnImmediately" => true })
      assert_equal "TASK_STATE_COMPLETED", state_of(immediate)

      echo = send_to("plain-1", "ping")
      assert_equal "TASK_STATE_COMPLETED", state_of(echo)
      assert_equal "ping", status_text(echo)

      asked = send_to("tck-input-required-1", "need input")
      assert_equal "TASK_STATE_INPUT_REQUIRED", state_of(asked)

      rejected = send_to("tck-reject-task-1", "no")
      assert_equal "TASK_STATE_REJECTED", state_of(rejected)
      assert_equal "rejected", status_text(rejected)

      text = send_to("tck-artifact-text-1", "make text")
      assert_equal "Generated text content", text.dig("result", "task", "artifacts", 0, "parts", 0, "text")

      file = send_to("tck-artifact-file-1", "make file")
      file_part = file.dig("result", "task", "artifacts", 0, "parts", 0)
      assert_equal "output.txt", file_part["filename"]
      assert_equal "text/plain", file_part["mediaType"]
      assert_equal A2a::Conformance::FILE_BYTES, file_part["raw"]
      assert_nil file_part["text"]
      assert_nil file_part["url"]

      url = send_to("tck-artifact-file-url-1", "make url")
      url_part = url.dig("result", "task", "artifacts", 0, "parts", 0)
      assert_equal "https://example.com/output.txt", url_part["url"]
      assert_equal "output.txt", url_part["filename"]
      assert_equal "text/plain", url_part["mediaType"]
      assert_nil url_part["raw"]

      data = send_to("tck-artifact-data-1", "make data")
      assert_equal({ "key" => "value", "count" => 42 }, data.dig("result", "task", "artifacts", 0, "parts", 0, "data"))

      direct = send_to("tck-message-response-1", "just talk", configuration: {})
      assert_equal "Direct message response", direct.dig("result", "message", "parts", 0, "text")
      assert_equal "ROLE_AGENT", direct.dig("result", "message", "role")
      assert_nil direct.dig("result", "task")
      assert_not direct.dig("result", "message", "contextId").blank?
    end
  end

  test "a follow-up on an input-required task can complete it, and a trailing slash still hits the endpoint" do
    with_memory_cache do
      opened = send_to("tck-input-required-follow", "wait")
      task_id = opened.dig("result", "task", "id")
      context_id = opened.dig("result", "task", "contextId")

      again = send_to("tck-input-required-follow-2", "still waiting", task_id: task_id, context_id: context_id)
      assert_equal "TASK_STATE_INPUT_REQUIRED", state_of(again)
      assert_equal task_id, again.dig("result", "task", "id")

      done = send_to("tck-complete-task-follow", "thanks", task_id: task_id, context_id: context_id)
      assert_equal "TASK_STATE_COMPLETED", state_of(done)
      assert_equal "Hello from TCK", status_text(done)

      post "/a2a/concourse/conformance/",
        params: {
          jsonrpc: "2.0",
          id: "slash",
          method: "SendMessage",
          params: message_params("slash", message_id: "slash-1", configuration: { "returnImmediately" => true })
        }.to_json,
        headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer token-a", "A2A-Version" => "1.0" }
      assert_response :success
      assert_equal "TASK_STATE_COMPLETED", response.parsed_body.dig("result", "task", "status", "state")
    end
  end

  test "an unsupported media type is ContentTypeNotSupportedError, not a successful task" do
    with_memory_cache do
      body = rpc(
        owner: "concourse", agent: "conformance", token: "token-a", method: "SendMessage",
        params: {
          "message" => {
            "role" => "ROLE_USER",
            "parts" => [ { "raw" => "dGNr", "mediaType" => "application/x-unsupported-tck-type" } ],
            "messageId" => "tck-send-003-local"
          }
        }
      )

      assert_equal(-32005, body.dig("error", "code"))
      assert_equal "CONTENT_TYPE_NOT_SUPPORTED", body.dig("error", "data", 0, "reason")
      assert_nil body["result"]
    end
  end

  private

  def send_to(message_id, text, configuration: { "returnImmediately" => true }, task_id: nil, context_id: nil)
    rpc(
      owner: "concourse",
      agent: "conformance",
      token: "token-a",
      method: "SendMessage",
      params: message_params(text, message_id: message_id, configuration: configuration, context_id: context_id).tap { |params|
        params["message"]["taskId"] = task_id if task_id
      }
    )
  end

  def state_of(body)
    body.dig("result", "task", "status", "state")
  end

  def status_text(body)
    body.dig("result", "task", "status", "message", "parts", 0, "text")
  end

  def message_params(text, message_id:, configuration:, context_id: nil)
    message = {
      "role" => "ROLE_USER",
      "parts" => [ { "text" => text } ],
      "messageId" => message_id
    }
    message["contextId"] = context_id if context_id
    { "message" => message, "configuration" => configuration }
  end
end
