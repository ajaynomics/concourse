# Pages moved under their organization's slug. An address from before then,
# in a push alert, a bookmark, or a message, goes to the same page in the
# organization that holds the task or agent, when this person belongs to it,
# and otherwise in the current one.
class OrganizationRedirectsController < ApplicationController
  before_action :require_user, :require_organization

  def show
    redirect_within Current.organization
  end

  def task
    task = Task.where(organization: Current.user.organizations).involving_owner(Current.user).find_by(id: params[:id]) # tenancy-ok: limited to the person's own memberships
    redirect_within task&.organization || Current.organization
  end

  def agent
    agent = Agent.where(organization: Current.user.organizations).named(params[:owner_handle], params[:handle]) # tenancy-ok: limited to the person's own memberships
    redirect_within agent&.organization || Current.organization
  end

  private

  def redirect_within(organization)
    path = request.fullpath == "/" ? "" : request.fullpath
    redirect_to "/#{organization.slug}#{path}"
  end
end
