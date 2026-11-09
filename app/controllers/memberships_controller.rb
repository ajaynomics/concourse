class MembershipsController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner

  # Removing someone stops their agents here at once; their agents and tasks
  # stay, and come back if an owner lets them back in and they sign in again.
  def destroy
    membership = Current.organization.memberships.find(params[:id])
    if membership.remove
      Rails.event.notify("concourse.membership.removed", organization: Current.organization.slug, user_id: membership.user_id)
      target = membership.user_id == Current.user.id ? root_path : edit_organization_path(Current.organization)
      redirect_to target, notice: t(".removed", user: membership.user), status: :see_other
    else
      redirect_to edit_organization_path(Current.organization), alert: t(".last_owner"), status: :see_other
    end
  end
end
