# Owners decline a request to join. Declining records a removal, so the next
# sign-in does not ask again; letting them back in clears it.
class JoinRequestsController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner

  def destroy
    join_request = Current.organization.join_requests.find(params[:id])
    join_request.decline
    Rails.event.notify("concourse.membership.declined", organization: Current.organization.slug, user_id: join_request.user_id)
    redirect_to edit_organization_path(Current.organization), notice: t(".declined", user: join_request.user), status: :see_other
  end
end
