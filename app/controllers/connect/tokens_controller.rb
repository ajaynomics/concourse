module Connect
  # The app's server redeems a /connect code for the agent's credential
  # (RFC 6749 §4.1.3, PKCE per RFC 7636 §4.6). A server-to-server call with
  # no session, so no CSRF; the code, its PKCE verifier and the exact
  # redirect URI are the proof.
  class TokensController < ActionController::API
    include NotAVisit

    rate_limit to: 30, within: 1.minute

    def create
      # RFC 6749 §5.1: a response carrying a credential is never cached.
      response.set_header("Cache-Control", "no-store")
      response.set_header("Pragma", "no-cache")
      return oauth_error("invalid_request") if params[:grant_type].blank?
      return oauth_error("unsupported_grant_type") unless params[:grant_type] == "authorization_code"
      return oauth_error("invalid_request") unless %i[code redirect_uri code_verifier].all? { |key| params[key].is_a?(String) && params[key].present? }

      grant = ConnectGrant.find_by(code_digest: ConnectGrant.digest(params[:code])) # tenancy-ok: the one-time code is the credential; no organization precedes it
      raise ConnectGrant::Invalid unless grant

      secret = grant.redeem!(redirect_uri: params[:redirect_uri], code_verifier: params[:code_verifier])
      Rails.event.notify("concourse.agent.connect_redeemed", organization: grant.agent.organization.slug, agent_id: grant.agent_id)
      render json: credential(grant, secret)
    rescue ConnectGrant::Invalid
      oauth_error("invalid_grant")
    end

    private

    def credential(grant, secret)
      agent = grant.agent
      {
        agent: { address: A2a::Card.endpoint_url(agent), organization: agent.organization.slug, handle: agent.handle, status: grant.agent_status },
        client_id: grant.client_id,
        client_secret: secret,
        token_endpoint: "#{Concourse.authorization_server}/oauth/token",
        scope: AgentAuthentication::SCOPE,
        resources: { api_and_a2a: Concourse.app_url, mcp: "#{Concourse.app_url}/mcp" }
      }
    end

    # RFC 6749 §5.2.
    def oauth_error(error)
      render json: { error: error }, status: :bad_request
    end
  end
end
