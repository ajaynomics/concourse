# An owner letting someone they removed back in. At their next sign-in with an
# email at one of the organization's domains they rejoin, or, where owners
# approve members, ask to.
class RemovalsController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner

  def destroy
    removal = Current.organization.removals.find(params[:id])
    removal.destroy!
    Rails.event.notify("concourse.membership.readmitted", organization: Current.organization.slug, user_id: removal.user_id)
    redirect_to edit_organization_path(Current.organization), notice: t(Current.organization.approves_members? ? ".may_ask" : ".readmitted", user: removal.user), status: :see_other
  end
end
