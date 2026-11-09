require "test_helper"

class ProjectsTest < ActionDispatch::IntegrationTest
  setup do
    @organization = Organization.default
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ @organization ])
    @riley = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ @organization ])
    @codex = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a")
    @pi = Agent.create!(owner: @riley, handle: "pi", oauth_client_id: "client-b")
    @flights = @organization.projects.create!(name: "Flights", description: "Search and booking.", agents: [ @pi ])
    @hotels = @organization.projects.create!(name: "Hotels")
  end

  test "a member creates and renames a project, and the directory narrows to it" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    post projects_path(@organization), params: { project: { name: "Auto trips", description: "Trips planned for you." } }
    assert_redirected_to agents_path(@organization, project: "auto-trips")

    patch project_path(@organization, "auto-trips"), params: { project: { name: "Road trips" } }
    assert_equal "Road trips", @organization.projects.find_by!(slug: "auto-trips").name

    get agents_path(@organization, project: "flights")
    assert_response :success
    assert_includes response.body, "Search and booking."
    assert_select "a.row .handle", text: "riley/pi", count: 1
    assert_select "a.row .handle", text: "ajay/codex", count: 0

    get agents_path(@organization, project: "nowhere")
    assert_response :not_found
  end

  test "only an owner deletes a project, and its agents stay" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    delete project_path(@organization, @flights)
    assert_response :not_found

    @ajay.memberships.sole.update!(role: "owner")
    delete project_path(@organization, @flights)
    assert_redirected_to projects_path(@organization)
    assert_not @organization.projects.exists?(slug: "flights")
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

    patch agent_path(@organization, "ajay", "codex"), params: { agent: { name: "Codex", project_slugs: [ "", "flights", "hotels" ] } }
    assert_equal [ "flights", "hotels" ], @codex.reload.projects.map(&:slug)

    patch agent_path(@organization, "ajay", "codex"), params: { agent: { name: "Codex 2" } }
    assert_equal [ "flights", "hotels" ], @codex.reload.projects.map(&:slug)

    patch agent_path(@organization, "ajay", "codex"), params: { agent: { project_slugs: [ "" ] } }
    assert_empty @codex.reload.projects
  end

  test "agents list projects, filter by one, and join with update_card" do
    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      stub_agent_token("mcp-a", client_id: "client-a", sub: "42", resource: :mcp)

      get "/api/projects", headers: bearer("token-a")
      assert_equal [ [ "flights", 1 ], [ "hotels", 0 ] ], response.parsed_body["projects"].map { |project| project.values_at("slug", "agents") }

      get "/agents", params: { project: "flights" }, headers: bearer("token-a")
      assert_equal [ "riley/pi" ], response.parsed_body["agents"].map { |agent| agent["handle"] }
      assert_equal [ "flights" ], response.parsed_body.dig("agents", 0, "projects")

      get "/agents", params: { project: "nowhere" }, headers: bearer("token-a")
      assert_response :not_found

      patch api_card_path, params: { projects: [ "hotels" ] }.to_json, headers: bearer("token-a").merge("CONTENT_TYPE" => "application/json")
      assert_equal [ "hotels" ], response.parsed_body.dig("capabilities", "extensions", 0, "params", "projects")

      listed = mcp_call("mcp-a", "list_projects")
      assert_equal [ "flights", "hotels" ], listed.dig("result", "structuredContent", "projects").map { |project| project["slug"] }

      joined = mcp_call("mcp-a", "update_card", { "projects" => [ "flights", "hotels" ] })
      assert_equal [ "flights", "hotels" ], joined.dig("result", "structuredContent", "capabilities", "extensions", 0, "params", "projects")

      found = mcp_call("mcp-a", "find_agents", { "project" => "flights" })
      assert_equal [ "ajay/codex", "riley/pi" ], found.dig("result", "structuredContent", "agents").map { |agent| agent["handle"] }

      unknown = mcp_call("mcp-a", "find_agents", { "project" => "nowhere" })
      assert_equal true, unknown.dig("result", "isError")
    end
  end

  test "update_card refuses a project that isn't the organization's and changes nothing" do
    elsewhere = Organization.create!(name: "Elsewhere")
    elsewhere.projects.create!(name: "Secret")
    @codex.update!(projects: [ @flights ])

    [ [ "secret" ], [ "flights", "nowhere" ], "flights", [ 1 ] ].each do |projects|
      assert_raises(A2a::Error) { A2a::Exchange.update_card(@codex, name: "Changed", projects: projects) }
    end
    assert_equal [ "flights" ], @codex.reload.projects.map(&:slug)
    assert_nil @codex.name

    A2a::Exchange.update_card(@codex, name: "Kept")
    assert_equal [ "flights" ], @codex.reload.projects.map(&:slug)
  end

  test "the public card says nothing about projects" do
    get "/a2a/riley/pi/.well-known/agent-card.json"

    assert_not_includes response.body, "flights"
  end

  private

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
