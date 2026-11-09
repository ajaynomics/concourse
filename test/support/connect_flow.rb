require_relative "machine_clients"

# A web app joining through /connect, with Ajent's minting endpoint stubbed
# at the HTTP call it receives.
module ConnectFlow
  include MachineClients

  AGENT_CLIENTS = "http://www.example.com/oauth/concourse_v3/agent_clients"
  REDIRECT_URI = "https://app.example/callback?tenant=7"

  def setup_connect
    setup_machine_client
    @owner.update!(email: "owner@machine.test", email_verified: true)
    @ajent_settings = Rails.application.config.x.ajent
    @previous_ajent = @ajent_settings.to_h.dup
    @ajent_settings.agent_clients_client_id = "concourse-joins"
    @ajent_settings.agent_clients_client_secret = "joins-secret"
    @verifier = SecureRandom.urlsafe_base64(48)
    @connect_params = {
      response_type: "code", redirect_uri: REDIRECT_URI, state: "app-state-1",
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false),
      code_challenge_method: "S256", handle: "assistant", name: "Assistant", app_name: "Durable Assistants"
    }
  end

  def teardown_connect
    @ajent_settings.agent_clients_client_id = @previous_ajent[:agent_clients_client_id]
    @ajent_settings.agent_clients_client_secret = @previous_ajent[:agent_clients_client_secret]
    restore_machine_settings
  end

  def stub_mint(status: 201, client_id: "minted-client", client_secret: "minted-secret", owner_sub: @owner.ajent_sub)
    stub_request(:post, AGENT_CLIENTS).to_return(
      status: status, headers: { "Content-Type" => "application/json" },
      body: { client_id: client_id, client_secret: client_secret, owner_sub: owner_sub }.to_json
    )
  end

  def stub_revoke(client_id = "minted-client", status: 204)
    stub_request(:delete, "#{AGENT_CLIENTS}/#{client_id}").to_return(status: status)
  end

  def sign_in_owner
    sign_in_via_ajent(subject: @owner.ajent_sub, email: @owner.email, name: "Owner")
  end

  # Approves on the consent page and returns the code from the redirect.
  def approve(organization: @organization, **overrides)
    post connect_path, params: @connect_params.merge(organization: organization.slug).merge(overrides)
    assert_response :see_other
    callback = URI(response.location)
    Rack::Utils.parse_query(callback.query).fetch("code")
  end

  def redeem(code, **overrides)
    post connect_token_path, params: {
      grant_type: "authorization_code", code: code, redirect_uri: REDIRECT_URI, code_verifier: @verifier
    }.merge(overrides)
    response.parsed_body
  end

  def connected_payload(client_id = "minted-client")
    @payload.merge("client_id" => client_id)
  end
end
