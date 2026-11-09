require "test_helper"

class WorkerApiTest < ActionDispatch::IntegrationTest
  setup do
    owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    other = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    @caller = Agent.create!(owner: owner, handle: "codex", oauth_client_id: "client-a")
    @recipient = Agent.create!(owner: other, handle: "pi", oauth_client_id: "client-b")
    @task = Task.open!(recipient: @recipient, caller: @caller)
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "work this" } ])
  end

  test "only the recipient may list or change the inbox, and others get 404" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      stub_agent_token("token-b", client_id: "client-b", sub: "7")

      get worker_inbox_path(@caller.id), headers: bearer("token-a")
      assert_response :success
      assert_empty response.parsed_body["tasks"]

      get worker_inbox_path(@recipient), headers: bearer("token-a")
      assert_response :not_found

      get worker_inbox_path(@recipient), headers: bearer("token-b")
      assert_response :success
      task = response.parsed_body.dig("tasks", 0)
      assert_equal @task.id, task["id"]
      assert_equal "ajay/codex", task.dig("metadata", "concourse.caller")
      assert_equal "ajay/codex", task.dig("history", 0, "metadata", "concourse.caller")

      patch worker_task_path(@task),
        params: { state: "TASK_STATE_WORKING", message: { parts: [ { text: "on it" } ] } }.to_json,
        headers: bearer("token-a").merge("CONTENT_TYPE" => "application/json")
      assert_response :not_found
      assert_equal "TASK_STATE_SUBMITTED", @task.reload.state

      patch worker_task_path(@task),
        params: { state: "TASK_STATE_INPUT_REQUIRED", message: { parts: [ { text: "need a file" } ] } }.to_json,
        headers: bearer("token-b").merge("CONTENT_TYPE" => "application/json")
      assert_response :success
      assert_equal "TASK_STATE_INPUT_REQUIRED", response.parsed_body.dig("status", "state")
      assert_equal "ROLE_AGENT", @task.messages.order(:created_at).last.role
    end
  end

  test "bad JSON is 400 and does not record a message" do
    with_memory_cache do
      stub_agent_token("token-b", client_id: "client-b", sub: "7")
      assert_no_difference -> { @task.messages.count } do
        patch worker_task_path(@task), params: "{", headers: bearer("token-b").merge("CONTENT_TYPE" => "application/json")
        assert_response :bad_request

        post worker_task_messages_path(@task), params: "not-json", headers: bearer("token-b").merge("CONTENT_TYPE" => "application/json")
        assert_response :bad_request
      end
    end
  end

  test "an invalid transition does not keep the message" do
    with_memory_cache do
      stub_agent_token("token-b", client_id: "client-b", sub: "7")
      assert_no_difference -> { Message.count } do
        patch worker_task_path(@task),
          params: { state: "TASK_STATE_SUBMITTED", message: { parts: [ { text: "should roll back" } ] } }.to_json,
          headers: bearer("token-b").merge("CONTENT_TYPE" => "application/json")
        assert_response :unprocessable_entity
      end
      assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
    end
  end

  test "a reply without a state is a new status the caller can see" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      stub_agent_token("token-b", client_id: "client-b", sub: "7")
      patch worker_task_path(@task), params: { state: "TASK_STATE_WORKING" }.to_json,
        headers: bearer("token-b").merge("CONTENT_TYPE" => "application/json")
      assert_response :success
      before = @task.reload.status_at

      # travel_to drops sub-second time, so go two seconds ahead and filter at one.
      travel_to before + 2.seconds do
        post worker_task_messages_path(@task), params: { parts: [ { text: "found it" } ] }.to_json,
          headers: bearer("token-b").merge("CONTENT_TYPE" => "application/json")
        assert_response :success
      end
      @task.reload
      assert_equal "TASK_STATE_WORKING", @task.state
      assert_operator @task.status_at, :>, before

      get "/api/tasks", params: { statusTimestampAfter: (before + 1.second).utc.iso8601(3) }, headers: bearer("token-a")
      assert_response :success
      listed = response.parsed_body["tasks"].sole
      assert_equal @task.id, listed["id"]
      assert_equal "riley/pi", listed.dig("metadata", "concourse.recipient")
      assert_equal "found it", listed.dig("status", "message", "parts", 0, "text")

      get "/api/tasks", headers: bearer("token-b")
      assert_nil response.parsed_body.dig("tasks", 0, "metadata", "concourse.recipient")
    end
  end

  private

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
