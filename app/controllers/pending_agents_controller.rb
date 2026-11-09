# Agents waiting for an owner of an organization that approves agents.
class PendingAgentsController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner

  def destroy
    agent = Current.organization.agents.pending.find(params[:id])
    agent.decline
    Rails.event.notify("concourse.agent.declined", organization: Current.organization.slug, agent_id: agent.id)
    # Owners act from settings, the agents page or this page; go back there.
    redirect_back_or_to edit_organization_path(Current.organization), notice: t(".declined", owner: agent.owner), status: :see_other
  end
end
