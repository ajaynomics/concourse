require "test_helper"
require_relative "../support/machine_clients"

class V3OrganizationSelectionTest < ActionDispatch::IntegrationTest
  include MachineClients

  setup do
    setup_machine_client
    @old_release = @machine_settings.release_line
    @machine_settings.release_line = 3
    @second = Organization.create!(name: "Second Lab", slug: "second-lab")
    @outsider = Organization.create!(name: "Private Lab", slug: "private-lab")
    @owner.memberships.create!(organization: @second)
    Current.reset
  end

  teardown do
    @machine_settings.release_line = @old_release
    restore_machine_settings
    Current.reset
  end

  test "ambiguous enrollment is an actionable 409 and rolls back owner enrichment" do
    human_token
    without_identity_changes { get api_identity_path, headers: bearer }
    assert_conflict "organization_required"
    assert_equal choices, response.parsed_body.fetch("organizations")
    assert_includes response.parsed_body.fetch("message"), "Concourse-Organization"
    assert_not_includes response.body, @outsider.slug
  end

  test "a selected fresh membership enrolls only there and route or payload does not select" do
    human_token
    without_identity_changes do
      get api_identity_path, params: { organization: @second.slug }, headers: bearer
    end
    assert_conflict "organization_required"
    get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug)
    assert_response :success
    assert_equal @second.slug, response.parsed_body.fetch("organization")
    assert_equal @second.id, @owner.agents.find_by!(oauth_client_id: "new-client").organization_id
    assert_equal "fresh@example.test", @owner.reload.email
    assert_equal "Fresh Name", @owner.name
  end

  test "zero membership stays forbidden and one membership needs no header" do
    human_token
    @owner.memberships.where(organization: @second).delete_all
    get api_identity_path, headers: bearer
    assert_response :success
    assert_equal @organization.slug, response.parsed_body.fetch("organization")
    @owner.memberships.delete_all
    human_token(client_id: "unadmitted-client")
    without_identity_changes { get api_identity_path, headers: bearer }
    assert_response :forbidden
    assert_equal "not_a_member", response.parsed_body.fetch("error")
  end

  test "blank malformed unknown nonmember and removed selections fail safely without enrollment" do
    human_token
    [ "", " ", "Machine-Lab", "machine-lab,second-lab", "../machine-lab", "unknown", @outsider.slug ].each do |slug|
      without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => slug) }
      assert_conflict "organization_invalid"
      assert_equal choices, response.parsed_body.fetch("organizations")
    end
    @owner.memberships.where(organization: @second).delete_all
    without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug) }
    assert_conflict "organization_invalid"
    assert_equal [ { "slug" => @organization.slug, "name" => @organization.name } ], response.parsed_body.fetch("organizations")
  end

  test "a cached token does not cache selection or membership and can retry with a permitted choice" do
    with_memory_cache do
      human_token
      get api_identity_path, headers: bearer
      assert_conflict "organization_required"
      @owner.memberships.where(organization: @second).delete_all
      without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug) }
      assert_conflict "organization_invalid"
      get api_identity_path, headers: bearer.merge("Concourse-Organization" => @organization.slug)
      assert_response :success
      assert_equal @organization.slug, response.parsed_body.fetch("organization")
      assert_requested :post, AgentTokens::INTROSPECT, times: 1
    end
  end

  test "bound human clients retain their organization and reject conflicting or invalid choices" do
    human_token(client_id: "human-profile")
    get api_identity_path, headers: bearer
    assert_response :success
    assert_equal @agent.id, response.parsed_body.fetch("agent_id")
    without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug) }
    assert_conflict "organization_conflict"
    without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @outsider.slug) }
    assert_conflict "organization_invalid"
    get api_identity_path, headers: bearer.merge("Concourse-Organization" => @organization.slug)
    assert_response :success
    @owner.memberships.where(organization: @organization).delete_all
    without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug) }
    assert_response :forbidden
    assert_equal @organization.id, @agent.reload.organization_id
  end

  test "bound machines never enroll or move and conflicting selection is not invalid credentials" do
    stub_machine
    get api_identity_path, headers: bearer
    assert_response :success
    without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug) }
    assert_conflict "organization_conflict"
    without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => "") }
    assert_conflict "organization_invalid"
    get api_identity_path, headers: bearer.merge("Concourse-Organization" => @organization.slug)
    assert_response :success
    assert_equal @agent.id, response.parsed_body.fetch("agent_id")
    assert_equal "machine-client", @binding.reload.client_id
    assert_equal "human-profile", @agent.reload.oauth_client_id
  end

  test "bad credentials expose no membership choices including unbound or revoked machines" do
    human = @payload.merge("client_id" => "new-client", "sub" => @owner.ajent_sub)
    [ human.merge("active" => false), human.merge("aud" => "https://wrong.example.test"), human.merge("scope" => "openid"),
      @payload.merge("client_id" => "unbound-machine") ].each do |payload|
      stub_machine(payload)
      without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug) }
      assert_response :unauthorized
      assert_empty response.body
      without_identity_changes { post_rpc("/a2a/#{@second.slug}/unknown/pi", id: "unauthorized-1", organization: @second.slug) }
      assert_response :unauthorized
      assert_empty response.body
    end
    @binding.revoke!
    stub_machine
    without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug) }
    assert_response :unauthorized
    assert_empty response.body
  end

  test "removed machine membership is rechecked before selection even with cached credentials" do
    with_memory_cache do
      stub_machine
      get api_identity_path, headers: bearer
      assert_response :success
      @owner.memberships.where(organization: @organization).delete_all
      without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug) }
      assert_response :unauthorized
      assert_empty response.body
      assert_requested :post, AgentTokens::INTROSPECT, times: 1
    end
  end

  test "never admitted human credentials cannot enroll even with a selected organization" do
    human_token(sub: "never-signed-in")
    without_identity_changes { get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug) }
    assert_response :forbidden
    assert_equal "not_a_member", response.parsed_body.fetch("error")
    assert_not response.parsed_body.key?("organizations")
  end

  # A2A v1.0 §9.5: an error has the request ID and no result. The conflict
  # is enrollment authorization, not a token challenge or recipient lookup.
  test "JSON-RPC carries the same conflict data and preserves string numeric and null request IDs" do
    human_token
    get api_identity_path, headers: bearer
    expected = response.parsed_body
    [ "selection-1", 17, nil ].each do |id|
      without_identity_changes { post_rpc("/a2a/#{@second.slug}/unknown/pi", id: id) }
      assert_response :conflict
      body = response.parsed_body
      assert_equal "2.0", body.fetch("jsonrpc")
      id.nil? ? assert_nil(body.fetch("id")) : assert_equal(id, body.fetch("id"))
      assert_not body.key?("result")
      assert_equal(-32600, body.dig("error", "code"))
      assert_equal expected, body.dig("error", "data")
      assert_nil response.headers["WWW-Authenticate"]
    end
    human_token(aud: "#{Concourse.app_url}/mcp")
    without_identity_changes { post_rpc("/mcp", id: 29) }
    assert_response :conflict
    assert_equal 29, response.parsed_body.fetch("id")
    assert_equal expected, response.parsed_body.dig("error", "data")
  end

  test "JSON-RPC invalid selection and existing binding conflict also carry structured data" do
    human_token(client_id: "human-profile")
    { @second.slug => "organization_conflict", @outsider.slug => "organization_invalid" }.each do |slug, error|
      without_identity_changes { post_rpc("/a2a/#{@second.slug}/unknown/pi", id: "conflict-#{error}", organization: slug) }
      assert_response :conflict
      assert_equal "conflict-#{error}", response.parsed_body.fetch("id")
      assert_equal error, response.parsed_body.dig("error", "data", "error")
      assert_equal choices, response.parsed_body.dig("error", "data", "organizations")
      assert_nil response.headers["WWW-Authenticate"]
    end
  end

  test "legacy human allocation and machine binding ignore the v3 selection header" do
    @machine_settings.release_line = 1
    human_token
    get api_identity_path, headers: bearer.merge("Concourse-Organization" => @outsider.slug)
    assert_response :success
    assert_equal @owner.first_organization.slug, response.parsed_body.fetch("organization")
    stub_machine
    get api_identity_path, headers: bearer.merge("Concourse-Organization" => @second.slug)
    assert_response :success
    assert_equal @agent.id, response.parsed_body.fetch("agent_id")
    assert_equal @organization.id, @agent.reload.organization_id
  end

  private

  def human_token(client_id: "new-client", sub: @owner.ajent_sub, aud: Concourse.app_url)
    stub_machine(@payload.merge("client_id" => client_id, "sub" => sub, "aud" => aud, "email" => "fresh@example.test", "name" => "Fresh Name"))
  end

  def bearer
    { "Authorization" => "Bearer machine-token" }
  end

  def post_rpc(path, id:, organization: nil)
    headers = bearer.merge("CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json", "A2A-Version" => "1.0")
    headers["Concourse-Organization"] = organization unless organization.nil?
    post path, params: { jsonrpc: "2.0", id: id, method: "GetTask", params: {} }.to_json, headers: headers
  end

  def assert_conflict(error)
    assert_response :conflict
    assert_equal error, response.parsed_body.fetch("error")
    assert_nil response.headers["WWW-Authenticate"]
  end

  def choices
    [ @organization, @second ].sort_by(&:slug).map { |organization| { "slug" => organization.slug, "name" => organization.name } }
  end

  def without_identity_changes
    owner_attributes = @owner.reload.attributes
    agent_attributes = @agent.reload.attributes
    binding_attributes = @binding.reload.attributes
    assert_no_difference [ -> { User.count }, -> { Agent.count }, -> { Membership.count }, -> { Agent::ClientBinding.count }, -> { Task.count }, -> { Message.count } ] do
      yield
    end
    assert_equal owner_attributes, @owner.reload.attributes
    assert_equal agent_attributes, @agent.reload.attributes
    assert_equal binding_attributes, @binding.reload.attributes
  end
end
