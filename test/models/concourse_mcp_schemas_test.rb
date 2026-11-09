require "test_helper"

# Codemode and other programmatic MCP clients read structuredContent typed by
# each tool's outputSchema. Every tool's real result must match its schema,
# and tools/list must advertise the schema and accurate annotations.
class ConcourseMcpSchemasTest < ActiveSupport::TestCase
  setup do
    organization = Organization.default
    @caller = Agent.create!(owner: User.create!(ajent_sub: "schema-a", handle: "ann", organizations: [ organization ]), handle: "asker")
    @recipient = Agent.create!(owner: User.create!(ajent_sub: "schema-b", handle: "bob", organizations: [ organization ]), handle: "worker",
      description: "Works.", skills: [ { "id" => "w", "name" => "Work", "description" => "Does work.", "tags" => [ "w" ] } ])
    organization.projects.create!(name: "Accounts", agents: [ @recipient ])
  end

  test "every tool advertises an output schema and annotations" do
    ConcourseMcp.tools.each do |tool|
      listed = tool.to_h
      assert listed[:outputSchema], "#{tool.tool_name} has no outputSchema"
      # MCP 2025-06-18: outputSchema must be an object schema at the top level; strict clients
      # (the Python MCP SDK in Hermes) reject the whole tools/list otherwise.
      assert_equal "object", listed.dig(:outputSchema, :type), "#{tool.tool_name} outputSchema lacks type: object"
      assert_includes [ true, false ], listed.dig(:annotations, :readOnlyHint), "#{tool.tool_name} has no readOnlyHint"
    end
    read_only = ConcourseMcp.tools.select { |tool| tool.to_h.dig(:annotations, :readOnlyHint) }.map(&:tool_name)
    assert_equal %w[find_agents get_task list_pending_agents list_projects list_tasks next_task], read_only.sort
  end

  test "real results of every tool match their output schemas" do
    A2a::Exchange.with_limits(inbox: 0) do
      card = call(UpdateCardTool, @recipient, name: "Worker", projects: [ "accounts" ])
      call(FindAgentsTool, @caller, query: "worker")
      call(ListProjectsTool, @caller)
      assert_nil call(NextTaskTool, @recipient, wait: 0)["task"]

      sent = call(SendMessageTool, @caller, to: "bob/worker", text: "Plan it")
      assert_equal "TASK_STATE_SUBMITTED", sent.dig("status", "state")
      picked = call(NextTaskTool, @recipient, wait: 0)
      assert_equal sent["id"], picked.dig("task", "id")
      replied = call(ReplyTool, @recipient, task_id: sent["id"], text: "Done", state: "TASK_STATE_COMPLETED", artifact_name: "plan", artifact_text: "the plan")
      assert_equal "TASK_STATE_COMPLETED", replied.dig("status", "state")
      call(GetTaskTool, @caller, id: sent["id"])
      page = call(ListTasksTool, @caller, include_artifacts: true)
      assert_equal [ sent["id"] ], page["tasks"].map { |task| task["id"] }
      assert card["name"]
    end
  end

  test "real results of the owner tools match their output schemas" do
    organization = Organization.default
    organization.memberships.find_by!(user: @caller.owner).update!(role: "owner")
    waiting = Agent.create!(owner: @recipient.owner, organization: organization, oauth_client_id: "schema-new", admitted_at: nil)
    other = Agent.create!(owner: @recipient.owner, organization: organization, oauth_client_id: "schema-other", admitted_at: nil)
    context = ConcourseMcp::Context.new(agent: @caller, credential_subject: "schema-a")

    assert_equal [ waiting.id, other.id ], call(ListPendingAgentsTool, context)["agents"].pluck("id")
    assert_equal "admitted", call(ApproveAgentTool, context, agent_id: waiting.id)["status"]
    assert_equal "declined", call(DeclineAgentTool, context, agent_id: other.id)["status"]
    assert_equal "declined", call(RetireAgentTool, context, agent_id: waiting.id)["status"]
    # The directory gives the id these tools take.
    assert_equal @recipient.id, call(FindAgentsTool, context, query: "worker")["agents"].sole["id"]

    refused = ApproveAgentTool.call(server_context: ConcourseMcp::Context.new(agent: @caller), agent_id: waiting.id)
    assert refused.error?
    assert_equal({ "code" => "machine_client", "message" => refused.structured_content["message"] }, refused.structured_content)
  end

  test "a direct Message answer (A2A 3.1.1) is sent as its wire hash, not a struct" do
    payload = { "messageId" => "m", "role" => "ROLE_AGENT", "contextId" => "c", "parts" => [ { "text" => "hi" } ] }
    response = ConcourseMcp.result(A2a::DirectMessage.new(payload: payload))
    assert_equal payload, response.structured_content
    assert_equal payload, JSON.parse(response.content.first[:text])
    SendMessageTool.output_schema.validate_result(payload)
  end

  test "failures are error results that carry code and message" do
    response = GetTaskTool.call(server_context: ConcourseMcp::Context.new(agent: @caller), id: "missing")
    assert response.error?
    assert_equal %w[code message], response.structured_content.keys
  end

  private

  def call(tool, agent, **arguments)
    context = agent.is_a?(ConcourseMcp::Context) ? agent : ConcourseMcp::Context.new(agent: agent)
    response = tool.call(server_context: context, **arguments)
    assert_not response.error?, "#{tool.tool_name}: #{response.structured_content}"
    tool.output_schema.validate_result(JSON.parse(JSON.generate(response.structured_content)))
    response.structured_content
  end
end
