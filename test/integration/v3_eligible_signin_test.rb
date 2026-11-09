require "test_helper"

class V3EligibleSigninTest < ActionDispatch::IntegrationTest
  setup do
    @settings = Rails.application.config.x.concourse
    @previous_release = @settings.release_line
    @settings.release_line = 3
    Current.reset
    @organization = Organization.create!(name: "Eligible Lab", slug: "eligible-lab", email_domains: "eligible.example")
  end

  teardown do
    @settings.release_line = @previous_release
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:ajent] = nil
    Current.reset
  end

  # These exercise the consumer boundary with synthetic introspection and OIDC
  # UserInfo, not a claim that the issuer has deployed automatic registration.
  test "verified web sign in admits the subject and fresh public clients bind independently" do
    human_token("first-token", client_id: "fresh-first-client")
    assert_no_enrollment { get api_identity_path, headers: bearer("first-token") }
    assert_response :forbidden
    assert_equal "not_a_member", response.parsed_body.fetch("error")

    sign_in_via_ajent(subject: "eligible-subject", email: "karl@eligible.example", name: "Eligible Person")
    owner = User.find_by!(ajent_sub: "eligible-subject")
    assert_equal "member", owner.membership_in(@organization).role
    assert_equal [ @organization.id ], owner.organizations.pluck(:id)

    assert_difference -> { owner.agents.count }, 1 do
      get api_identity_path, params: { owner: "forged-owner", oauth_client_id: "forged-client" }, headers: bearer("first-token")
    end
    assert_response :success
    first = response.parsed_body
    assert_equal owner.handle, first.fetch("owner")
    assert_equal "fresh-first-client", first.fetch("oauth_client_id")
    assert_equal @organization.slug, first.fetch("organization")

    patch api_card_path, params: { handle: "first-bot", name: "First Bot", harness: "pi" }, headers: bearer("first-token"), as: :json
    assert_response :success
    assert_no_difference -> { owner.agents.count } do
      get api_identity_path, headers: bearer("first-token")
    end
    assert_equal first.fetch("agent_id"), response.parsed_body.fetch("agent_id")
    assert_equal "first-bot", response.parsed_body.fetch("handle")

    human_token("second-token", client_id: "fresh-second-client")
    assert_difference -> { owner.agents.count }, 1 do
      get api_identity_path, headers: bearer("second-token")
    end
    assert_response :success
    assert_not_equal first.fetch("agent_id"), response.parsed_body.fetch("agent_id")
    assert_equal "fresh-second-client", response.parsed_body.fetch("oauth_client_id")
    assert_equal "fresh-first-client", owner.agents.find(first.fetch("agent_id")).oauth_client_id
  end

  test "unverified and other domain accounts gain no membership or agent from a token" do
    [ [ "unverified-subject", "karl@eligible.example", false ], [ "outside-subject", "karl@outside.example", true ] ].each do |subject, email, verified|
      sign_in_via_ajent(subject: subject, email: email, email_verified: verified)
      owner = User.find_by!(ajent_sub: subject)
      assert_empty owner.organizations
      human_token("#{subject}-token", client_id: "#{subject}-client", subject: subject, email: email)
      assert_no_enrollment { get api_identity_path, headers: bearer("#{subject}-token") }
      assert_response :forbidden
      assert_equal "not_a_member", response.parsed_body.fetch("error")
      assert_empty owner.agents
    end
  end

  test "fresh web sign in does not reverse removal and a token cannot readmit" do
    sign_in_via_ajent(subject: "eligible-subject", email: "karl@eligible.example")
    owner = User.find_by!(ajent_sub: "eligible-subject")
    assert owner.membership_in(@organization).remove
    assert @organization.removals.exists?(user: owner)
    sign_in_via_ajent(subject: "eligible-subject", email: "karl@eligible.example")
    assert_empty owner.reload.organizations
    human_token("removed-token", client_id: "fresh-removed-client")
    assert_no_enrollment { get api_identity_path, headers: bearer("removed-token") }
    assert_response :forbidden
    assert_equal "not_a_member", response.parsed_body.fetch("error")
  end

  test "eligible membership does not turn a legacy audience or missing scope into v3 credentials" do
    sign_in_via_ajent(subject: "eligible-subject", email: "karl@eligible.example")
    [ { "aud" => "https://legacy.example" }, { "aud" => "#{Concourse.app_url}/mcp" }, { "scope" => "openid profile email" } ].each_with_index do |changes, index|
      token = "wrong-boundary-#{index}"
      payload = human_payload("wrong-boundary-client-#{index}").merge(changes)
      stub_request(:post, AgentTokens::INTROSPECT).with(body: hash_including("token" => token)).to_return(
        status: 200, body: payload.to_json, headers: { "Content-Type" => "application/json" }
      )
      assert_no_enrollment { get api_identity_path, headers: bearer(token) }
      assert_response :unauthorized
      assert_empty response.body
      assert_includes response.headers.fetch("WWW-Authenticate"), 'error="invalid_token"'
    end
  end

  private

  def human_token(token, client_id:, subject: "eligible-subject", email: "karl@eligible.example")
    stub_agent_token(token, client_id: client_id, sub: subject, email: email, organization: nil)
  end

  def human_payload(client_id)
    { "active" => true, "scope" => "concourse", "client_id" => client_id, "sub" => "eligible-subject",
      "aud" => Concourse.app_url, "exp" => 30.minutes.from_now.to_i, "email" => "karl@eligible.example" }
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token}", "Concourse-Organization" => @organization.slug }
  end

  def assert_no_enrollment
    assert_no_difference [ -> { User.count }, -> { Membership.count }, -> { Agent.count }, -> { Agent::ClientBinding.count } ] do
      yield
    end
  end
end
