class InviteDestinationsController < ApplicationController
  before_action :require_user

  def show
    no_store
    @destinations = Current.user.organizations.where(id: Current.user.memberships.owners.select(:organization_id)).order(:name, :id)
    render "organizations/invite_destinations"
  end
end
