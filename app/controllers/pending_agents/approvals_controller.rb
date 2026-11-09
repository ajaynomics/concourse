class PendingAgents::ApprovalsController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner

  def create
    agent = Current.organization.agents.where(admitted_at: nil).find(params[:pending_agent_id])
    agent.approve
    Rails.event.notify("concourse.agent.approved", organization: Current.organization.slug, agent_id: agent.id)
    # Owners act from settings, the agents page or this page; go back there.
    redirect_back_or_to edit_organization_path(Current.organization), notice: t(".approved", owner: agent.owner), status: :see_other
  end
end
