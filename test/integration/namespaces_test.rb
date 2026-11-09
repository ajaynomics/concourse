require "test_helper"

class NamespacesTest < ActionDispatch::IntegrationTest
  setup do
    @harbor = Organization.create!(name: "Harbor")
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay")
    @member = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ @harbor ])
    @harbor.memberships.create!(user: @owner, role: "owner")
    @jane = Agent.create!(owner: @owner, organization: @harbor, handle: "jane", oauth_client_id: "client-jane")
  end

  test "an owner claims a namespace on the web and the agent's owner moves the agent under it" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    post namespaces_path(@harbor), params: { namespace: { name: "northwind" } }
    assert_redirected_to edit_organization_path(@harbor)
    namespace = @harbor.namespaces.sole
    post namespaces_path(@harbor), params: { namespace: { name: "riley" } }
    assert_match "Couldn't claim riley", flash[:alert]

    get edit_agent_path(@harbor, "ajay", "jane")
    assert_select "select[name='agent[namespace_id]'] option", 2
    patch agent_path(@harbor, "ajay", "jane"), params: { agent: { namespace_id: namespace.id } }
    assert_redirected_to agent_path(@harbor, "northwind", "jane")
    follow_redirect!
    assert_response :success
    get agent_path(@harbor, "ajay", "jane")
    assert_response :not_found

    delete namespace_path(@harbor, "northwind")
    assert_equal "northwind still has agents. Move them out first.", flash[:alert]
    patch agent_path(@harbor, "northwind", "jane"), params: { agent: { namespace_id: "" } }
    assert_redirected_to agent_path(@harbor, "ajay", "jane")
    delete namespace_path(@harbor, "northwind")
    assert_empty @harbor.namespaces.reload
  end

  test "members and agent tokens can't claim or release namespaces" do
    @harbor.namespaces.create!(name: "northwind")
    sign_in_via_ajent(subject: "7", email: "riley@example.com", name: "Riley")
    post namespaces_path(@harbor), params: { namespace: { name: "rileyspace" } }
    assert_response :not_found
    delete namespace_path(@harbor, "northwind")
    assert_response :not_found
    reset!

    stub_agent_token("token-ajay", client_id: "client-jane", sub: "42", organization: @harbor)
    post namespaces_path(@harbor), params: { namespace: { name: "tokenspace" } }, headers: { "Authorization" => "Bearer token-ajay" }
    assert_not_equal 303, response.status
    assert_equal [ "northwind" ], @harbor.namespaces.reload.map(&:name)
  end

  test "a namespaced agent answers at its prefix and says so in its identity" do
    namespace = @harbor.namespaces.create!(name: "northwind")
    @jane.update!(namespace: namespace)
    stub_agent_token("token-ajay", client_id: "client-jane", sub: "42", organization: @harbor)

    get "/a2a/harbor/northwind/jane/.well-known/agent-card.json"
    assert_equal "northwind/jane", response.parsed_body["name"]
    assert_equal "#{Concourse.app_url}/a2a/harbor/northwind/jane", response.parsed_body.dig("supportedInterfaces", 0, "url")
    get "/a2a/harbor/ajay/jane/.well-known/agent-card.json"
    assert_response :not_found

    body = rpc(owner: "northwind", agent: "jane", token: "token-ajay", method: "GetExtendedAgentCard", organization: @harbor)
    assert_equal "northwind", body.dig("result", "capabilities", "extensions", 0, "params", "namespace")
    assert_equal "ajay", body.dig("result", "capabilities", "extensions", 0, "params", "owner")

    settings = Rails.application.config.x.concourse
    previous, settings.release_line = settings.release_line, 3
    get "/api/identity", headers: { "Authorization" => "Bearer token-ajay" }
    assert_equal [ "ajay", "jane", "northwind" ], response.parsed_body.values_at("owner", "handle", "prefix")
  ensure
    settings.release_line = previous if settings
  end
end
