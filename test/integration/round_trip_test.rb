require "test_helper"

class RoundTripTest < ActionDispatch::IntegrationTest
  test "two agents complete a task through the bridge" do
    User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    Agent.create!(owner: User.find_by!(handle: "ajay"), handle: "codex", oauth_client_id: "client-a")
    Agent.create!(owner: User.find_by!(handle: "riley"), handle: "pi", oauth_client_id: "client-b")

    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42", resource: :mcp)
      stub_agent_token("token-b", client_id: "client-b", sub: "7", resource: :mcp)
      A2a::Exchange.with_limits(inbox: 0.2) do
        sent = mcp_call("token-a", "send_message", { "to" => "riley/pi", "text" => "please review the branch" })
        task_id = sent.dig("result", "structuredContent", "id")

        picked = mcp_call("token-b", "next_task")
        assert_equal task_id, picked.dig("result", "structuredContent", "task", "id")
        assert_equal "ajay/codex", picked.dig("result", "structuredContent", "task", "metadata", "concourse.caller")

        asked = mcp_call("token-b", "reply", { "task_id" => task_id, "text" => "which file?", "state" => "TASK_STATE_INPUT_REQUIRED" })
        assert_equal "TASK_STATE_INPUT_REQUIRED", asked.dig("result", "structuredContent", "status", "state")

        mcp_call("token-a", "send_message", { "to" => "riley/pi", "text" => "app/models/task.rb", "task_id" => task_id })
        answered = mcp_call("token-b", "next_task")
        assert_equal task_id, answered.dig("result", "structuredContent", "task", "id")

        done = mcp_call("token-b", "reply", {
          "task_id" => task_id,
          "state" => "TASK_STATE_COMPLETED",
          "artifact_name" => "review",
          "artifact_text" => "looks good"
        })
        assert_equal "TASK_STATE_COMPLETED", done.dig("result", "structuredContent", "status", "state")

        changed = mcp_call("token-a", "list_tasks", { "status_timestamp_after" => 1.minute.ago.utc.iso8601(3) })
        listed = changed.dig("result", "structuredContent", "tasks").sole
        assert_equal task_id, listed["id"]
        assert_equal "riley/pi", listed.dig("metadata", "concourse.recipient")
        later = mcp_call("token-a", "list_tasks", { "status_timestamp_after" => 1.minute.from_now.utc.iso8601(3) })
        assert_empty later.dig("result", "structuredContent", "tasks")

        seen = mcp_call("token-a", "get_task", { "id" => task_id })
        task = seen.dig("result", "structuredContent")
        assert_equal "TASK_STATE_COMPLETED", task.dig("status", "state")
        assert_equal "looks good", task.dig("artifacts", 0, "parts", 0, "text")
      end
    end
  end
end
