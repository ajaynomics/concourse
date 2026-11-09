require "test_helper"

# wait 0 returns at once, an out-of-range wait is invalid_params, and no wait
# keeps the 45-second cap.
class McpNextTaskWaitTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @agent = Agent.create!(owner: @owner, oauth_client_id: "client-a", handle: "codex")
  end

  test "next_task wait shortens the cap and rejects out-of-range waits" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42", email: "ajay@example.com", resource: :mcp)
      A2a::Exchange.with_limits(inbox: 0) do
        empty = mcp_call("token-a", "next_task", { "wait" => 0 })
        assert_nil empty.dig("result", "structuredContent", "task")

        too_long = mcp_call("token-a", "next_task", { "wait" => 99 })
        assert_equal true, too_long.dig("result", "isError")

        negative = mcp_call("token-a", "next_task", { "wait" => -1 })
        assert_equal true, negative.dig("result", "isError")
      end
    end
  end
end
