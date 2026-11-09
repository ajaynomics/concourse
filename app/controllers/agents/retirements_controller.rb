class Agents::RetirementsController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner, :set_agent

  def show
  end

  def create
    values = params.expect(retirement: [ :agent_id, :confirmation, :admitted_at ])
    confirmed = @agent.with_lock do
      # A moved or renamed record is no longer this scoped address.
      raise ActiveRecord::RecordNotFound unless @agent.organization_id == Current.organization.id &&
        @agent.qualified_handle == "#{params[:owner_handle]}/#{params[:handle]}"

      # An old form may reconcile withdrawal, but never withdraw a later approval.
      next false unless values[:agent_id] == @agent.id.to_s && values[:confirmation] == @agent.qualified_handle &&
        (@agent.admitted_at.nil? || values[:admitted_at] == @agent.admitted_at.iso8601(6))

      @agent.retire
      true
    end

    if confirmed
      Rails.event.notify("concourse.agent.retired", organization: Current.organization.slug, agent_id: @agent.id)
      # Owners act from settings, the agents page or this page; go back there.
      redirect_back_or_to retirement_path(Current.organization, @agent.prefix, @agent.handle), notice: t(".retired"), status: :see_other
    else
      @confirmation_error = true
      render :show, status: :unprocessable_content
    end
  end

  private

  def set_agent
    # Admission is deliberately not required: an owner must be able to reconcile
    # an uncertain retirement without re-admitting the agent or replaying a write.
    @agent = Current.organization.agents.at_address(params[:owner_handle], params[:handle]).first!
    # The network agent is the organization's own service, not a member's agent.
    raise ActiveRecord::RecordNotFound if @agent.owner.system?
  end
end
