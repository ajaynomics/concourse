class JoinRequests::ApprovalsController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner

  def create
    join_request = Current.organization.join_requests.find(params[:join_request_id])
    join_request.approve
    Rails.event.notify("concourse.membership.joined", organization: Current.organization.slug, user_id: join_request.user_id)
    redirect_to edit_organization_path(Current.organization), notice: t(".approved", user: join_request.user), status: :see_other
  end
end
