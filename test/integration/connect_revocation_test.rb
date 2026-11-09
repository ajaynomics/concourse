require "test_helper"
require_relative "../support/connect_flow"

# Disconnecting: the app retires its own agent, or an owner retires it.
# Either way Concourse refuses the credential at once and asks Ajent to
# revoke the client afterwards, without depending on Ajent being up.
class ConnectRevocationTest < ActionDispatch::IntegrationTest
  include ConnectFlow
  include ActiveJob::TestHelper

  setup do
    setup_connect
    @organization.memberships.find_by!(user: @owner).update!(role: "owner")
    stub_mint
    sign_in_owner
    redeem(approve)
    @connected = @owner.agents.find_by!(handle: "assistant")
    stub_machine(connected_payload, token: "connected-token")
  end

  teardown { teardown_connect }

  test "the app's own token retires its agent and Ajent revokes the client" do
    revoke = stub_revoke
    assert_enqueued_with(job: RevokeAgentClientJob, args: [ @organization.id, "minted-client" ]) do
      post connect_revocation_path, headers: bearer("connected-token")
    end
    assert_response :no_content
    assert @connected.reload.declined_at
    assert_not @connected.admitted?
    assert @connected.client_binding.revoked_at
    assert_nil @organization.agents.named(@owner.handle, "assistant")

    post connect_revocation_path, headers: bearer("connected-token")
    assert_response :unauthorized
    get api_identity_path, headers: bearer("connected-token")
    assert_response :unauthorized

    perform_enqueued_jobs only: RevokeAgentClientJob
    assert_requested revoke

    # A later join makes a fresh agent; the old address stays retired.
    stub_mint(client_id: "fresh-client")
    code = approve(handle: "assistant-2")
    assert_equal "admitted", redeem(code).dig("agent", "status")
    assert_not_equal @connected.id, @owner.agents.find_by!(handle: "assistant-2").id
  end

  test "an agent waiting for approval can still be disconnected by its app" do
    @connected.update!(admitted_at: nil)
    post connect_revocation_path, headers: bearer("connected-token")
    assert_response :no_content
    assert @connected.reload.declined_at
    assert @connected.client_binding.revoked_at
  end

  test "only a connected agent's own client credential may disconnect" do
    stub_machine
    post connect_revocation_path, headers: bearer("machine-token")
    assert_response :forbidden
    assert_equal "not_a_connected_agent", response.parsed_body["error"]
    assert_nil @binding.reload.revoked_at

    stub_agent_token("human-token", client_id: "human-profile", sub: @owner.ajent_sub, organization: nil)
    post connect_revocation_path, headers: bearer("human-token")
    assert_response :forbidden
    assert @agent.reload.admitted?

    post connect_revocation_path
    assert_response :unauthorized
    assert @connected.reload.admitted?
    assert_nil @connected.client_binding.revoked_at
  end

  test "an owner's retirement revokes at Ajent and refuses locally even while Ajent is down" do
    stub_revoke(status: 503)
    assert_enqueued_with(job: RevokeAgentClientJob, args: [ @organization.id, "minted-client" ]) do
      post retirement_path(@organization, @owner.handle, "assistant"), params: {
        retirement: { agent_id: @connected.id, confirmation: @connected.qualified_handle, admitted_at: @connected.admitted_at.iso8601(6) }
      }
    end
    assert @connected.reload.client_binding.revoked_at

    assert_enqueued_with(job: RevokeAgentClientJob) { RevokeAgentClientJob.perform_now(@organization.id, "minted-client") }
    get api_identity_path, headers: bearer("connected-token")
    assert_response :unauthorized
  end

  test "an operator-bound client is revoked locally only" do
    assert_no_enqueued_jobs only: RevokeAgentClientJob do
      @agent.retire
    end
    assert @binding.reload.revoked_at
  end

  test "Ajent's revoke treats gone as done and reports a refusal without retrying" do
    stub_revoke(status: 404)
    assert RevokeAgentClientJob.perform_now(@organization.id, "minted-client")
    stub_revoke(status: 401)
    assert_no_enqueued_jobs { RevokeAgentClientJob.perform_now(@organization.id, "minted-client") }
  end

  private

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
