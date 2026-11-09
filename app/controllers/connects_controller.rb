# /connect: a web app sends a signed-in person here to make it an agent
# (RFC 6749 §4.1 with PKCE). The person picks an organization and a handle and
# approves; Concourse creates the agent, Ajent mints its client, and the app
# gets a one-time code it exchanges at /connect/token.
class ConnectsController < ApplicationController
  rate_limit to: 30, within: 1.minute

  before_action :protect_response, :set_connect_request
  before_action :require_minting, :require_signed_in, except: :destroy
  before_action :set_organizations, except: :destroy

  # Chrome checks a form's redirect target against form-action, so the
  # consent page permits exactly the requesting app's origin.
  content_security_policy do |policy|
    policy.form_action(*policy.directives["form-action"], -> { @connect_request&.redirect_origin if @connect_request&.errors&.none? })
  end

  def show
    @organization = @organizations.first
    @agent = build_agent(@connect_request.handle)
    @agent.validate if @agent.handle
  end

  def create
    @organization = @organizations.find { |organization| organization.slug == params[:organization] }
    @agent = build_agent(params[:handle])
    return refuse(:organization) unless @organization

    # Blank is the person's own handle. Agent validates that a namespace is
    # the chosen organization's, the same rule as moving one on its edit page.
    namespace = @namespaces.find { |candidate| candidate.name == params[:prefix] } if params[:prefix].present?
    return refuse(:prefix) if params[:prefix].present? && !namespace

    grant, code = ConnectGrant.approve!(owner: Current.user, organization: @organization, namespace: namespace,
      handle: @agent.handle, request: @connect_request)
    Rails.event.notify("concourse.agent.connected", organization: @organization.slug, agent_id: grant.agent_id)
    redirect_to @connect_request.callback_url(code: code), allow_other_host: true, status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    return refuse(:failed) unless error.record.is_a?(Agent)

    @agent = error.record
    render :show, status: :unprocessable_content
  rescue Ajent::AgentClients::Rejected
    refuse(:refused)
  rescue Ajent::AgentClients::Error
    refuse(:unavailable, status: :service_unavailable)
  end

  # Cancel (RFC 6749 §4.1.2.1). Nothing was created.
  def destroy
    redirect_to @connect_request.callback_url(error: "access_denied"), allow_other_host: true, status: :see_other
  end

  private

  # A task elsewhere in the organization must not refresh this page and move
  # Approve or Cancel under the person's pointer.
  def live_updates?
    false
  end

  def protect_response
    # The page carries the app's state; keep it out of caches and referrers.
    response.set_header("Cache-Control", "no-store")
    response.set_header("Referrer-Policy", "strict-origin")
  end

  def set_connect_request
    @connect_request = ConnectRequest.from(params)
    render :invalid, status: :bad_request unless @connect_request.valid?
  end

  def require_minting
    render :unavailable, status: :service_unavailable unless Ajent::AgentClients.configured?
  end

  # Sign-in resets the session, so SessionsController brings the same
  # request back here afterwards.
  def require_signed_in
    return if signed_in?

    session[ConnectRequest::SESSION_KEY] = @connect_request.to_session
    redirect_to sign_in_path
  end

  # Only organizations the person belongs to now whose owners let apps join.
  def set_organizations
    @organizations = Current.user.organizations.skip_query_cache!.order(:name).select { |organization| Agent::ClientBinding.organization_allowed?(organization) }
    # Any member may put an agent under one of its organization's namespaces.
    @namespaces = @organizations.flat_map { |organization| organization.namespaces.to_a }.sort_by(&:name)
    return if @organizations.any?

    # An owner can turn it on, so the page points them at where.
    @owned_organizations = Current.user.organizations.merge(Membership.owners).order(:name).reject(&:legacy?)
    render :show, status: :forbidden
  end

  def build_agent(handle)
    Current.user.agents.build(organization: @organization, handle: handle.presence, name: @connect_request.name.presence)
  end

  def refuse(reason, status: :unprocessable_content)
    @failure = reason
    @organization ||= @organizations.first
    render :show, status: status
  end
end
