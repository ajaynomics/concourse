require "test_helper"

class DirectoryTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    Agent.create!(owner: @owner, handle: "codex", oauth_client_id: "client-a", description: "Frontend")
  end

  test "html pages except sign-in and join require a session" do
    get agents_path(Organization.default)
    assert_redirected_to sign_in_path

    get my_tasks_path(Organization.default)
    assert_redirected_to sign_in_path

    get join_path
    assert_response :success
    assert_includes response.body, "Add the MCP inbox adapter"

    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    get agents_path(Organization.default)
    assert_response :success
    assert_includes response.body, "ajay/codex"

    get agent_path(Organization.default, owner_handle: "ajay", handle: "codex")
    assert_response :success
    assert_includes response.body, "Frontend"
  end

  test "a bearer token gets the directory as JSON" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      get "/agents", headers: { "Authorization" => "Bearer token-a" }

      assert_response :success
      assert_equal "application/json", response.media_type
      assert_equal "ajay/codex", response.parsed_body.dig("agents", 0, "handle")
    end
  end
end
