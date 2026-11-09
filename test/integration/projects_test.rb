require "test_helper"

class ProjectsTest < ActionDispatch::IntegrationTest
  setup do
    @organization = Organization.default
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ @organization ])
    @riley = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ @organization ])
    @codex = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a")
    @pi = Agent.create!(owner: @riley, handle: "pi", oauth_client_id: "client-b")
    @accounts = @organization.projects.create!(name: "Accounts", description: "Search and checkout.", agents: [ @pi ])
    @invoices = @organization.projects.create!(name: "Invoices")
  end

  test "a member creates and renames a project, and the directory narrows to it" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    post projects_path(@organization), params: { project: { name: "Billing runs", description: "Runs scheduled for you." } }
    assert_redirected_to agents_path(@organization, project: "billing-runs")

    patch project_path(@organization, "billing-runs"), params: { project: { name: "Billing" } }
    assert_equal "Billing", @organization.projects.find_by!(slug: "billing-runs").name

    get agents_path(@organization, project: "accounts")
    assert_response :success
    assert_includes response.body, "Search and checkout."
    assert_select "a.row .handle", text: "riley/pi", count: 1
    assert_select "a.row .handle", text: "ajay/codex", count: 0

    get agents_path(@organization, project: "nowhere")
    assert_response :not_found
  end

  test "only an owner deletes a project, and its agents stay" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    delete project_path(@organization, @accounts)
    assert_response :not_found

    @ajay.memberships.sole.update!(role: "owner")
    delete project_path(@organization, @accounts)
    assert_redirected_to projects_path(@organization)
    assert_not @organization.projects.exists?(slug: "accounts")
    assert_empty @pi.reload.projects
  end

  test "another organization's project is not found" do
    elsewhere = Organization.create!(name: "Elsewhere")
    elsewhere.memberships.create!(user: @ajay)
    elsewhere.projects.create!(name: "Secret")
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    get edit_project_path(@organization, "secret")
    assert_response :not_found
  end

  test "an owner puts their agent in projects from its edit page, and an edit without the field keeps them" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    patch agent_path(@organization, "ajay", "codex"), params: { agent: { name: "Codex", project_slugs: [ "", "accounts", "invoices" ] } }
    assert_equal [ "accounts", "invoices" ], @codex.reload.projects.map(&:slug)

    patch agent_path(@organization, "ajay", "codex"), params: { agent: { name: "Codex 2" } }
    assert_equal [ "accounts", "invoices" ], @codex.reload.projects.map(&:slug)

    patch agent_path(@organization, "ajay", "codex"), params: { agent: { project_slugs: [ "" ] } }
    assert_empty @codex.reload.projects
  end

  test "agents list projects, filter by one, and join with update_card" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      stub_agent_token("mcp-a", client_id: "client-a", sub: "42", resource: :mcp)

      get "/api/projects", headers: bearer("token-a")
      assert_equal [ [ "accounts", 1 ], [ "invoices", 0 ] ], response.parsed_body["projects"].map { |project| project.values_at("slug", "agents") }

      get "/agents", params: { project: "accounts" }, headers: bearer("token-a")
      assert_equal [ "riley/pi" ], response.parsed_body["agents"].map { |agent| agent["handle"] }
      assert_equal [ "accounts" ], response.parsed_body.dig("agents", 0, "projects")

      get "/agents", params: { project: "nowhere" }, headers: bearer("token-a")
      assert_response :not_found

      patch api_card_path, params: { projects: [ "invoices" ] }.to_json, headers: bearer("token-a").merge("CONTENT_TYPE" => "application/json")
      assert_equal [ "invoices" ], response.parsed_body.dig("capabilities", "extensions", 0, "params", "projects")

      listed = mcp_call("mcp-a", "list_projects")
      assert_equal [ "accounts", "invoices" ], listed.dig("result", "structuredContent", "projects").map { |project| project["slug"] }

      joined = mcp_call("mcp-a", "update_card", { "projects" => [ "accounts", "invoices" ] })
      assert_equal [ "accounts", "invoices" ], joined.dig("result", "structuredContent", "capabilities", "extensions", 0, "params", "projects")

      found = mcp_call("mcp-a", "find_agents", { "project" => "accounts" })
      assert_equal [ "ajay/codex", "riley/pi" ], found.dig("result", "structuredContent", "agents").map { |agent| agent["handle"] }

      unknown = mcp_call("mcp-a", "find_agents", { "project" => "nowhere" })
      assert_equal true, unknown.dig("result", "isError")
    end
  end

  test "update_card refuses a project that isn't the organization's and changes nothing" do
    elsewhere = Organization.create!(name: "Elsewhere")
    elsewhere.projects.create!(name: "Secret")
    @codex.update!(projects: [ @accounts ])

    [ [ "secret" ], [ "accounts", "nowhere" ], "accounts", [ 1 ] ].each do |projects|
      assert_raises(A2a::Error) { A2a::Exchange.update_card(@codex, name: "Changed", projects: projects) }
    end
    assert_equal [ "accounts" ], @codex.reload.projects.map(&:slug)
    assert_nil @codex.name

    A2a::Exchange.update_card(@codex, name: "Kept")
    assert_equal [ "accounts" ], @codex.reload.projects.map(&:slug)
  end

  test "the public card says nothing about projects" do
    get "/a2a/riley/pi/.well-known/agent-card.json"

    assert_not_includes response.body, "accounts"
  end

  private

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
