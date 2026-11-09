# Bearer authentication for API controllers. A request without a token Ajent
# says is active, audience-bound to this app, and scoped to concourse never
# reaches the action. RFC 6750 for the error parameter; RFC 9728 for
# resource_metadata.
module AgentAuthentication
  extend ActiveSupport::Concern

  SCOPE = "concourse"
  UNAVAILABLE_RETRY_AFTER = "30"
  # Fresh inactive answers from Ajent one address may cause before it is
  # turned away without asking again. Only a token Ajent was actually asked
  # about counts: a repeated revoked token hits the cached answer and costs
  # nothing, and a token refused locally (audience, binding, admission) never
  # reached the issuer, so neither can lock out others sharing the address.
  FAILED_BEARER_LIMIT = 30
  FAILED_BEARER_WINDOW = 1.minute

  included do
    before_action :authenticate_agent!
  end

  def self.resource_metadata_url(path)
    suffix = mcp_path?(path) ? "/mcp" : ""
    "#{Concourse.app_url}/.well-known/oauth-protected-resource#{suffix}"
  end

  def self.mcp_path?(path)
    path == "/mcp" || path.to_s.start_with?("/mcp/")
  end

  def self.expected_audience(path)
    mcp_path?(path) ? "#{Concourse.app_url}/mcp" : Concourse.app_url
  end

  def self.www_authenticate(path:, token_presented:)
    parameters = [
      %(resource_metadata="#{resource_metadata_url(path)}"),
      %(scope="#{SCOPE}")
    ]
    parameters << %(error="invalid_token") if token_presented
    "Bearer #{parameters.join(", ")}"
  end

  private

  def authenticate_agent!
    if bearer_token.blank?
      render_unauthorized(token_presented: bearer_presented?)
      return
    end
    return render_throttled if bearer_failures_exhausted?

    payload = Ajent::Introspection.authenticate(bearer_token, audience: expected_audience)
    agent = Agent.establish_from_introspection!(payload, organization_slug: request.headers["Concourse-Organization"])
    Current.user = agent.owner
    Current.organization = agent.organization
    Current.agent = agent
    Current.credential_client_id = payload["client_id"]
    # The same test that sent this credential down the machine or the human
    # path, asked after admission so a client reserved meanwhile counts as a
    # machine. Only the human path may act for the owner.
    Current.credential_subject = payload["sub"].to_s unless Agent::ClientBinding.machine_payload?(payload)
    note_error_context
  rescue Ajent::Introspection::Inactive
    count_bearer_failure
    render_unauthorized(token_presented: true)
  rescue Ajent::Introspection::Rejected
    render_unauthorized(token_presented: true)
  rescue Ajent::Introspection::Unavailable
    render_unavailable
  rescue Agent::Unadmitted => error
    if allows_unadmitted_connected_agent? && error.client_binding&.connected?
      # The credential was verified for this live binding before admission
      # was checked, so the action may act on that agent, and only on it.
      Current.agent = error.client_binding.agent
      Current.credential_client_id = error.client_binding.client_id
    else
      render_unadmitted(error)
    end
  rescue Agent::OrganizationSelectionRequired => error
    render_organization_conflict(error)
  end

  # Only an app disconnecting its own /connect agent (Connect::RevocationsController)
  # may proceed while that agent awaits approval or was declined.
  def allows_unadmitted_connected_agent?
    false
  end

  def bearer_token
    scheme, token = request.authorization.to_s.split(" ", 2)
    return unless scheme == "Bearer"

    token.to_s.strip.presence
  end

  # Rails' rate_limit counts every request; only fresh inactive answers count
  # here, so busy agents sharing an address are never throttled by traffic.
  def bearer_failures_exhausted?
    Rails.cache.read(bearer_failures_key).to_i >= FAILED_BEARER_LIMIT
  end

  def count_bearer_failure
    Rails.cache.increment(bearer_failures_key, 1, expires_in: FAILED_BEARER_WINDOW)
  end

  def bearer_failures_key
    "agent_authentication/failures/#{request.remote_ip}"
  end

  # RFC 6585 §4.
  def render_throttled
    response.headers["Retry-After"] = FAILED_BEARER_WINDOW.to_i.to_s
    head :too_many_requests
  end

  def bearer_presented?
    request.authorization.to_s.start_with?("Bearer ")
  end

  # 401 is a rejected credential. An Ajent outage is not: Codex and Claude
  # Code treat invalid_token as "sign in again". 503 with Retry-After asks
  # them to wait. A cached token never reaches this path.
  def render_unavailable
    response.headers["Retry-After"] = UNAVAILABLE_RETRY_AFTER
    if jsonrpc_endpoint?
      render json: {
        jsonrpc: "2.0",
        id: jsonrpc_id,
        error: A2a::Error.new(:internal).to_h
      }, status: :service_unavailable
    else
      render json: { error: "unavailable" }, status: :service_unavailable
    end
  end

  # The token is good; the person is not in an organization that holds this
  # agent. 403, not 401: signing in to the agent's harness again would not
  # change the answer. Only the web can admit someone.
  def render_unadmitted(error)
    message = case error
    when Agent::AwaitingApproval
      "This agent is waiting for an owner of its organization to approve it at #{Concourse.app_url}. Try again after approval."
    when Agent::Declined
      "An owner of this agent's organization declined it. Signing in again will not change that; ask an owner to approve it at #{Concourse.app_url}."
    else
      "This account is not a member of an organization on Concourse that holds this agent. " \
        "Sign in on the web at #{Concourse.app_url} first."
    end
    if jsonrpc_endpoint?
      render json: {
        jsonrpc: "2.0",
        id: jsonrpc_id,
        error: { code: A2a::Error::CODES[:invalid_request], message: message }
      }, status: :forbidden
    else
      # error stays not_a_member, which released clients already read;
      # reason tells a waiting or declined agent apart.
      body = { error: "not_a_member", message: message }
      body[:reason] = "awaiting_approval" if error.is_a?(Agent::AwaitingApproval)
      body[:reason] = "declined" if error.is_a?(Agent::Declined)
      render json: body, status: :forbidden
    end
  end

  def render_organization_conflict(error)
    if jsonrpc_endpoint?
      render json: {
        jsonrpc: "2.0",
        id: jsonrpc_id,
        error: { code: A2a::Error::CODES[:invalid_request], message: error.message, data: error.data }
      }, status: :conflict
    else
      render json: error.data, status: :conflict
    end
  end

  def jsonrpc_endpoint?
    request.path.start_with?("/a2a/") || AgentAuthentication.mcp_path?(request.path)
  end

  def jsonrpc_id
    parsed = JSON.parse(request.raw_post)
    return unless parsed.is_a?(Hash)

    id = parsed["id"]
    id if id.is_a?(String) || id.is_a?(Numeric) || id.nil?
  rescue JSON::ParserError
    nil
  end

  def render_unauthorized(token_presented:)
    response.headers["WWW-Authenticate"] = AgentAuthentication.www_authenticate(
      path: request.path,
      token_presented: token_presented
    )
    head :unauthorized
  end

  def expected_audience
    AgentAuthentication.expected_audience(request.path)
  end

  # JSON-RPC method only. The body is not copied into the error context.
  def note_error_context
    Concourse::Glitchtip.note(
      route: request.path,
      http_method: request.request_method,
      agent: Current.agent,
      user: Current.user,
      organization: Current.organization,
      rpc_method: rpc_method_name,
      ip: request.remote_ip
    )
  end

  def rpc_method_name
    return unless request.path.start_with?("/a2a/")

    parsed = JSON.parse(request.raw_post)
    method = parsed.is_a?(Hash) ? parsed["method"] : nil
    method if method.is_a?(String) && method.match?(/\A[A-Za-z]{1,64}\z/)
  rescue JSON::ParserError
    nil
  end
end
