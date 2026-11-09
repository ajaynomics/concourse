require "test_helper"
require_relative "../support/machine_clients"

class V3IdentitySecurityTest < ActionDispatch::IntegrationTest
  include MachineClients

  setup do
    setup_machine_client
    @previous_release = @machine_settings.release_line
    @machine_settings.release_line = 3
    Current.reset
  end

  teardown do
    @machine_settings.release_line = @previous_release
    restore_machine_settings
    Current.reset
  end

  test "v3 reports the authenticated separately bound subject-free machine client only" do
    stub_machine
    assert_no_difference [ -> { User.count }, -> { Agent.count }, -> { Membership.count }, -> { Agent::ClientBinding.count } ] do
      get api_identity_path, params: {
        client_id: "forged", oauth_client_id: "forged", metadata: { "concourse.caller" => "forged" }
      }, headers: bearer
    end
    assert_response :success
    assert_equal expected_identity("machine-client"), response.parsed_body
    assert_equal "human-profile", @agent.reload.oauth_client_id
    assert_equal "machine-client", @binding.reload.client_id
    assert_nil @owner.reload.email
  end

  test "v3 human OAuth identity retains the authenticated human client" do
    stub_machine(@payload.merge("client_id" => "human-profile", "sub" => @owner.ajent_sub, "token_use" => "user"))
    get api_identity_path, headers: bearer
    assert_response :success
    assert_equal expected_identity("human-profile"), response.parsed_body
  end

  test "release one keeps the exact legacy response even for a separately bound machine" do
    @machine_settings.release_line = 1
    stub_machine
    get api_identity_path, headers: bearer
    assert_response :success
    expected = expected_identity("human-profile").except("release_line", "network_agent", "prefix")
    assert_equal expected.to_json, response.body
    assert_equal "human-profile", @agent.reload.oauth_client_id
  end

  test "invalid audience scope or unbound client never exposes identity or enrolls" do
    [ { "aud" => "https://wrong.example.test" }, { "scope" => "openid" }, { "client_id" => "unbound" } ].each do |changes|
      stub_machine(@payload.merge(changes))
      assert_no_difference [ -> { User.count }, -> { Agent.count }, -> { Membership.count }, -> { Agent::ClientBinding.count } ] do
        get api_identity_path, headers: bearer
      end
      assert_response :unauthorized
      assert_empty response.body
      assert_includes response.headers["WWW-Authenticate"], 'error="invalid_token"'
      assert_nil Current.credential_client_id
    end
  end

  test "removed membership denies even a cached credential without changing binding" do
    with_memory_cache do
      stub_machine
      get api_identity_path, headers: bearer
      assert_response :success
      @owner.memberships.delete_all
      get api_identity_path, headers: bearer
      assert_response :unauthorized
      assert_empty response.body
      assert_nil Current.credential_client_id
      assert_equal "machine-client", @binding.reload.client_id
      assert_equal "human-profile", @agent.reload.oauth_client_id
      assert_requested :post, AgentTokens::INTROSPECT, times: 1
    end
  end

  test "request identity resets across machine human and absent credentials" do
    assert_nil Current.credential_client_id
    Current.credential_client_id = "previous-request"
    Current.reset
    assert_nil Current.credential_client_id
    stub_machine
    get api_identity_path, headers: bearer
    assert_response :success
    assert_equal "machine-client", response.parsed_body.fetch("oauth_client_id")
    assert_nil Current.credential_client_id
    stub_machine(@payload.merge("client_id" => "human-profile", "sub" => @owner.ajent_sub), token: "human-token")
    get api_identity_path, headers: bearer("human-token")
    assert_response :success
    assert_equal "human-profile", response.parsed_body.fetch("oauth_client_id")
    assert_nil Current.credential_client_id
    get api_identity_path
    assert_response :unauthorized
    assert_empty response.body
    assert_nil Current.credential_client_id
  end

  private

  def bearer(token = "machine-token")
    { "Authorization" => "Bearer #{token}" }
  end

  def expected_identity(client_id)
    {
      "owner_id" => @owner.id, "owner" => @owner.handle,
      "organization" => @organization.slug, "agent_id" => @agent.id,
      "oauth_client_id" => client_id, "handle" => @agent.handle,
      "release_line" => 3, "network_agent" => A2a::Network.handle(@organization), "prefix" => @owner.handle
    }
  end
end
