require "test_helper"
require_relative "../support/connect_flow"

class ConnectTest < ActionDispatch::IntegrationTest
  include ConnectFlow
  include ActiveJob::TestHelper

  setup { setup_connect }
  teardown { teardown_connect }

  test "an invalid request renders an error page and never redirects to the app" do
    invalid = [
      { response_type: "token" }, { response_type: nil }, { code_challenge_method: "plain" }, { code_challenge: "short" },
      { state: nil }, { state: "x" * 513 }, { redirect_uri: nil }, { redirect_uri: "http://app.example/callback" },
      { redirect_uri: "https://app.example/callback#fragment" }, { redirect_uri: "javascript:alert(1)" },
      { redirect_uri: "https://user:pass@app.example/callback" }, { redirect_uri: "/relative" }, { redirect_uri: "https://" }
    ]
    [ false, true ].each do |signed_in|
      sign_in_owner if signed_in
      invalid.each do |changes|
        get connect_path(@connect_params.merge(changes).compact)
        assert_response :bad_request, changes.inspect
        assert_nil response.location
        assert_select "h1", text: "This connect link is not valid"
      end
    end
    post connect_path, params: @connect_params.merge(redirect_uri: "http://app.example/callback", organization: @organization.slug)
    assert_response :bad_request
    delete connect_path, params: @connect_params.merge(state: "")
    assert_response :bad_request
    assert_nil response.location
  end

  test "loopback redirects are accepted only outside production" do
    sign_in_owner
    get connect_path(@connect_params.merge(redirect_uri: "http://127.0.0.1:4567/callback"))
    assert_response :success
    assert ConnectRequest.from(@connect_params.merge(redirect_uri: "http://localhost:3000/cb")).valid?
    begin
      previous, Rails.env = Rails.env, "production"
      assert_not ConnectRequest.from(@connect_params.merge(redirect_uri: "http://127.0.0.1:4567/callback")).valid?
      assert ConnectRequest.from(@connect_params).valid?
    ensure
      Rails.env = previous
    end
  end

  test "without minting settings the page says connecting is not available yet" do
    @ajent_settings.agent_clients_client_secret = nil
    sign_in_owner
    get connect_path(@connect_params)
    assert_response :service_unavailable
    assert_select "h1", text: "Connecting apps is not available yet"
    assert_no_difference -> { Agent.count } do
      post connect_path, params: @connect_params.merge(organization: @organization.slug)
    end
    assert_response :service_unavailable
  end

  test "signing in returns to the same request" do
    get connect_path(@connect_params)
    assert_redirected_to sign_in_path
    sign_in_owner
    assert_equal "/connect", path
    assert_equal "app-state-1", request.params["state"]
    assert_equal REDIRECT_URI, request.params["redirect_uri"]
    assert_select "h1", text: "Connect an app as your agent"
    assert_select "strong", text: "app.example"
    assert_select "p", text: "This app calls itself “Durable Assistants”."
    assert_select "p", text: /An owner of the organization can retire it, and the app can disconnect it\./
    assert_select "input[type=radio][name=organization][value=?]", @organization.slug
    assert_select "code#connect_address", text: "machine-lab/machine-owner/assistant"
    assert_select "select[name=prefix] option[selected]", count: 0
    assert_select "select[name=prefix] option[value='']", text: "machine-owner (your handle)"
    assert_select "form[action='/connect'] input[type=hidden][name=state][value=?]", "app-state-1"
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_includes response.headers["Content-Security-Policy"], "https://app.example"
  end

  test "approving without a session asks for sign-in and creates nothing" do
    assert_no_difference -> { Agent.count } do
      post connect_path, params: @connect_params.merge(organization: @organization.slug)
    end
    assert_redirected_to sign_in_path
    assert_not_requested :post, AGENT_CLIENTS
  end

  test "the consent page holds still: no live refresh, and Cancel sits apart from Approve" do
    sign_in_owner
    get connect_path(@connect_params)
    assert_response :success
    assert_select "turbo-cable-stream-source", count: 0
    assert_select "form#connect_approval button[type=submit]", count: 0
    assert_select "button[type=submit][form=connect_approval]", text: "Approve", count: 1
    assert_select "div.justify-between button[type=submit][form=connect_approval] ~ form.ml-auto button", text: "Cancel"
  end

  test "only member organizations enabled for machine clients are offered or accepted" do
    elsewhere = Organization.create!(name: "Elsewhere", slug: "elsewhere", machine_clients: true)
    disabled = Organization.create!(name: "Disabled", slug: "disabled")
    disabled.memberships.create!(user: @owner)
    sign_in_owner

    get connect_path(@connect_params)
    assert_select "input[name=organization][value=?]", @organization.slug
    assert_select "input[name=organization][value=?]", elsewhere.slug, count: 0
    assert_select "input[name=organization][value=?]", disabled.slug, count: 0

    [ elsewhere, disabled ].each do |organization|
      assert_no_difference [ -> { Agent.count }, -> { Agent::ClientBinding.count } ] do
        post connect_path, params: @connect_params.merge(organization: organization.slug)
      end
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: /Choose one of the organizations/
    end
    assert_not_requested :post, AGENT_CLIENTS

    @organization.update!(machine_clients: false)
    get connect_path(@connect_params)
    assert_response :forbidden
    assert_select "[role=status]", text: /None of your organizations accepts connected apps/
    assert_select "[role=status] a", count: 0
  end

  test "with no organization accepting apps, an owner is pointed at the settings that turn it on" do
    @organization.update!(machine_clients: false)
    @organization.memberships.find_by!(user: @owner).update!(role: "owner")
    legacy = Organization.create!(name: "Legacy", slug: "legacy-lab")
    legacy.memberships.create!(user: @owner, role: "owner")
    @machine_settings.legacy_organization = legacy.slug
    sign_in_owner

    get connect_path(@connect_params)
    assert_response :forbidden
    assert_select "[role=status] a[href=?]", edit_organization_path(@organization), text: "Machine Lab settings"
    assert_select "[role=status] a[href=?]", edit_organization_path(legacy), count: 0
  end

  test "a taken or malformed handle is shown before approval and refused without minting" do
    sign_in_owner
    get connect_path(@connect_params.merge(handle: "worker"))
    assert_response :success
    assert_select "[role=alert]", text: /taken/
    [ "worker", "Not Valid", "" ].each do |handle|
      assert_no_difference [ -> { Agent.count }, -> { Agent::ClientBinding.count }, -> { ConnectGrant.count } ] do
        post connect_path, params: @connect_params.merge(organization: @organization.slug, handle: handle)
      end
      assert_response :unprocessable_content
    end
    assert_not_requested :post, AGENT_CLIENTS
  end

  test "the prefix is the person's handle or a namespace of the chosen organization, with the handle unique under it" do
    team = @organization.namespaces.create!(name: "team")
    other = Organization.create!(name: "Other Lab", slug: "other-lab", machine_clients: true)
    other.memberships.create!(user: @owner)
    elsewhere = other.namespaces.create!(name: "elsewhere")
    outside = Organization.create!(name: "Outside", slug: "outside").namespaces.create!(name: "outside")
    sign_in_owner

    get connect_path(@connect_params.merge(handle: "worker"))
    assert_select "select[name=prefix] option[value=team][data-organization=machine-lab]", text: "team (Machine Lab)"
    assert_select "select[name=prefix] option[value=elsewhere][data-organization=other-lab]"
    assert_select "select[name=prefix] option[value=outside]", count: 0
    assert_select "[role=alert]", text: /taken/

    [ [ elsewhere.name, /invalid/ ], [ outside.name, /address prefixes/ ], [ "nobody", /address prefixes/ ] ].each do |prefix, message|
      assert_no_difference -> { Agent.count } do
        post connect_path, params: @connect_params.merge(organization: @organization.slug, prefix: prefix, handle: "worker")
      end
      assert_response :unprocessable_content
      assert_select "[role=alert]", text: message
    end
    assert_not_requested :post, AGENT_CLIENTS

    stub_mint
    code = approve(prefix: "team", handle: "worker")
    agent = team.agents.sole
    assert_equal "team/worker", agent.qualified_handle
    assert_requested(:post, AGENT_CLIENTS) { |request| JSON.parse(request.body)["name"].end_with?("machine-lab/team/worker") }
    assert_equal "#{Concourse.app_url}/a2a/machine-lab/team/worker", redeem(code).dig("agent", "address")

    post connect_path, params: @connect_params.merge(organization: @organization.slug, prefix: "team", handle: "worker")
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /taken/
    assert_select "select[name=prefix] option[value=team][selected]"
  end

  test "cancel sends the person back with access_denied and the app's state" do
    sign_in_owner
    assert_no_difference -> { Agent.count } do
      delete connect_path, params: @connect_params
    end
    assert_redirected_to "https://app.example/callback?tenant=7&error=access_denied&state=app-state-1"
  end

  test "approval creates an admitted agent bound to the minted client and a one-time code" do
    stub_mint
    sign_in_owner
    code = nil
    assert_difference [ -> { Agent.count }, -> { Agent::ClientBinding.count }, -> { ConnectGrant.count } ], 1 do
      code = approve
    end
    callback = URI(response.location)
    assert_equal "app.example", callback.host
    assert_equal({ "tenant" => "7", "code" => code, "state" => "app-state-1" }, Rack::Utils.parse_query(callback.query))
    assert_requested(:post, AGENT_CLIENTS) do |request|
      body = JSON.parse(request.body)
      assert_equal "Basic #{Base64.strict_encode64('concourse-joins:joins-secret')}", request.headers["Authorization"]
      assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, request.headers["Idempotency-Key"])
      assert_equal @owner.ajent_sub, body["owner_sub"]
      assert_equal "Durable Assistants as machine-lab/machine-owner/assistant", body["name"]
      true
    end

    agent = @owner.agents.find_by!(handle: "assistant")
    assert agent.admitted?
    assert_equal "Assistant", agent.name
    assert_nil agent.oauth_client_id
    binding = agent.client_binding
    assert binding.connected?
    assert_equal "minted-client", binding.client_id
    grant = agent.connect_grants.sole
    assert_equal Digest::SHA256.hexdigest(code), grant.code_digest
    stored = ConnectGrant.connection.select_value("SELECT client_secret FROM connect_grants")
    assert_not_includes stored, "minted-secret"
    assert_equal "minted-secret", grant.client_secret
    assert_in_delta 10.minutes.from_now, grant.expires_at, 5.seconds
  end

  test "the app exchanges the code once for the agent's credential" do
    stub_mint
    sign_in_owner
    code = approve
    delete sign_out_path

    body = redeem(code)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({
      "agent" => { "address" => "#{Concourse.app_url}/a2a/machine-lab/machine-owner/assistant", "organization" => "machine-lab",
                   "handle" => "assistant", "status" => "admitted" },
      "client_id" => "minted-client", "client_secret" => "minted-secret",
      "token_endpoint" => "http://www.example.com/oauth/token", "scope" => "concourse",
      "resources" => { "api_and_a2a" => Concourse.app_url, "mcp" => "#{Concourse.app_url}/mcp" }
    }, body)
    grant = ConnectGrant.sole
    assert grant.used_at
    assert_nil grant.client_secret
    assert_nil ConnectGrant.connection.select_value("SELECT client_secret FROM connect_grants")

    assert_equal({ "error" => "invalid_grant" }, redeem(code))
    assert_response :bad_request

    stub_machine(connected_payload)
    get api_identity_path, headers: bearer
    assert_response :success
    assert_equal @owner.agents.find_by!(handle: "assistant").id, response.parsed_body["agent_id"]
  end

  test "the exchange refuses a wrong verifier, redirect, expired code and malformed requests" do
    stub_mint
    sign_in_owner
    code = approve
    [ { code_verifier: SecureRandom.urlsafe_base64(48) }, { code_verifier: "short" },
      { redirect_uri: "https://app.example/callback" }, { redirect_uri: "#{REDIRECT_URI}&more=1" },
      { code: "not-a-code" } ].each do |changes|
      assert_equal({ "error" => "invalid_grant" }, redeem(code, **changes), changes.inspect)
      assert_response :bad_request
    end
    assert_equal({ "error" => "unsupported_grant_type" }, redeem(code, grant_type: "client_credentials"))
    assert_equal({ "error" => "invalid_request" }, redeem(code, grant_type: nil))
    assert_equal({ "error" => "invalid_request" }, redeem(code, code_verifier: nil))
    assert_nil ConnectGrant.sole.used_at

    travel ConnectGrant::LIFETIME + 1.second do
      assert_equal({ "error" => "invalid_grant" }, redeem(code))
    end
    assert_equal "minted-secret", ConnectGrant.sole.client_secret
  end

  test "an organization that approves agents gets a waiting agent that works once approved" do
    @organization.update!(admission: "approval")
    @agent.approve
    @organization.memberships.find_by!(user: @owner).update!(role: "owner")
    stub_mint
    sign_in_owner
    get connect_path(@connect_params)
    assert_select "p", text: /waits for an owner/
    code = nil
    assert_enqueued_with(job: ApprovalAlertJob) { code = approve }
    agent = @owner.agents.find_by!(handle: "assistant")
    assert agent.pending?
    assert agent.client_binding.connected?

    assert_equal "awaiting_approval", redeem(code).dig("agent", "status")

    stub_machine(connected_payload)
    get api_identity_path, headers: bearer
    assert_response :forbidden
    assert_equal({ "error" => "not_a_member", "reason" => "awaiting_approval" }, response.parsed_body.slice("error", "reason"))

    post pending_agent_approval_path(@organization, agent)
    get api_identity_path, headers: bearer
    assert_response :success
    assert_equal agent.id, response.parsed_body["agent_id"]

    agent.reload.decline
    get api_identity_path, headers: bearer
    assert_response :forbidden
    assert_equal "declined", response.parsed_body["reason"]
  end

  test "a failed or refused mint leaves nothing and says so plainly" do
    sign_in_owner
    [ [ 401, :unprocessable_content, /would not create a credential/ ], [ 409, :unprocessable_content, /would not create/ ],
      [ 422, :unprocessable_content, /too many/ ], [ 503, :service_unavailable, /not answering/ ] ].each do |status, page, message|
      WebMock.reset!
      stub_request(:post, AGENT_CLIENTS).to_return(status: status, body: "{}")
      assert_no_difference [ -> { Agent.count }, -> { Agent::ClientBinding.count }, -> { ConnectGrant.count } ] do
        post connect_path, params: @connect_params.merge(organization: @organization.slug)
      end
      assert_response page
      assert_select "[role=alert]", text: message
      assert_select "[role=alert]", text: /Nothing was created/
      assert_no_enqueued_jobs only: RevokeAgentClientJob
    end
  end

  test "a lost answer is retried once with the same key, and a timeout leaves nothing" do
    keys = []
    stub_request(:post, AGENT_CLIENTS).with { |request| keys << request.headers["Idempotency-Key"] }.to_timeout
    sign_in_owner
    assert_no_difference [ -> { Agent.count }, -> { Agent::ClientBinding.count } ] do
      post connect_path, params: @connect_params.merge(organization: @organization.slug)
    end
    assert_response :service_unavailable
    assert_equal 2, keys.size
    assert_equal 1, keys.uniq.size
  end

  test "a binding failure after minting rolls back and revokes the minted client" do
    stub_mint(owner_sub: "someone-else")
    revoke = stub_revoke
    sign_in_owner
    assert_no_difference [ -> { Agent.count }, -> { Agent::ClientBinding.count }, -> { ConnectGrant.count } ] do
      assert_enqueued_with(job: RevokeAgentClientJob, args: [ @organization.id, "minted-client" ]) do
        post connect_path, params: @connect_params.merge(organization: @organization.slug)
      end
    end
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /Nothing was created/
    perform_enqueued_jobs only: RevokeAgentClientJob
    assert_requested revoke
  end

  test "a minted client ID that is already reserved here is never revoked" do
    stub_mint(client_id: @binding.client_id)
    sign_in_owner
    assert_no_difference [ -> { Agent.count }, -> { Agent::ClientBinding.count } ] do
      post connect_path, params: @connect_params.merge(organization: @organization.slug)
    end
    assert_response :unprocessable_content
    assert_no_enqueued_jobs only: RevokeAgentClientJob
    assert_nil @binding.reload.revoked_at
  end

  test "an agent retired before the app collects its code yields nothing" do
    stub_mint
    sign_in_owner
    code = approve
    @owner.agents.find_by!(handle: "assistant").retire
    assert_equal({ "error" => "invalid_grant" }, redeem(code))
    assert_equal "minted-secret", ConnectGrant.sole.client_secret
  end

  test "an approval the app never collects is retired when its grant is purged" do
    stub_mint
    sign_in_owner
    approve
    stub_mint(client_id: "collected-client")
    redeem(approve(handle: "collected"))
    abandoned = @owner.agents.find_by!(handle: "assistant")
    collected = @owner.agents.find_by!(handle: "collected")

    assert_no_enqueued_jobs(only: RevokeAgentClientJob) { ConnectGrant.purge_stale }
    assert abandoned.reload.admitted?

    travel ConnectGrant::LIFETIME + 1.second do
      assert_enqueued_with(job: RevokeAgentClientJob, args: [ @organization.id, "minted-client" ]) do
        assert_equal 1, ConnectGrant.purge_stale
      end
    end
    assert_not abandoned.reload.admitted?
    assert abandoned.declined_at
    assert abandoned.client_binding.revoked_at
    assert collected.reload.admitted?
    assert_nil collected.client_binding.revoked_at
    assert_empty ConnectGrant.all
  end

  test "stale grants are purged" do
    stub_mint
    sign_in_owner
    redeem(approve)
    stub_mint(client_id: "second-client")
    approve(handle: "second")
    fresh = ConnectGrant.where(used_at: nil).sole
    assert_equal 1, ConnectGrant.purge_stale
    assert_equal [ fresh ], ConnectGrant.all.to_a
    travel(ConnectGrant::LIFETIME + 1.second) { assert_equal 1, ConnectGrant.purge_stale }
  end

  test "codes, verifiers and secrets stay out of the request log" do
    stub_mint
    sign_in_owner
    code = nil
    logged = capture_log do
      code = approve
      redeem(code)
    end
    assert_includes logged, "/connect/token"
    [ code, @verifier, "minted-secret" ].each { |secret| assert_not_includes logged, secret }
  end

  private

  def bearer(token = "machine-token")
    { "Authorization" => "Bearer #{token}" }
  end

  def capture_log
    previous, record = Rails.logger, ActiveRecord::Base.logger
    buffer = StringIO.new
    Rails.logger = ActiveRecord::Base.logger = ActiveSupport::Logger.new(buffer)
    yield
    buffer.string
  ensure
    Rails.logger, ActiveRecord::Base.logger = previous, record
  end
end
