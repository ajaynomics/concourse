class Agents::NativeEndpointsController < ApplicationController
  before_action :require_user, :require_organization, :set_own_agent

  def show
    render json: @agent.native_registration.merge("activationAvailable" => false)
  end

  def create
    update
  end

  def update
    values = registration_params
    @agent.register_native_endpoint!(endpoint_url: values[:endpoint_url], card_url: values[:card_url],
      resource: values[:resource], tenant: values[:tenant])
    render json: @agent.native_registration.merge("activationAvailable" => false)
  rescue ActiveRecord::RecordInvalid
    render json: { error: "native_registration_unavailable" }, status: :unprocessable_content
  end

  def destroy
    @agent.remove_native_endpoint!
    head :no_content
  rescue ActiveRecord::RecordInvalid
    render json: { error: "native_route_locked" }, status: :unprocessable_content
  end

  private

  def set_own_agent
    @agent = Current.organization.agents.named(params[:owner_handle], params[:handle])
    raise ActiveRecord::RecordNotFound unless @agent && @agent.owner_id == Current.user.id
  end

  def registration_params
    params.expect(native_endpoint: [ :endpoint_url, :card_url, :resource, :tenant ])
  end
end
