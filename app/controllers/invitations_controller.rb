# Owners invite people by email. The invitation is the approval: the person
# joins at their next sign-in with that email verified.
class InvitationsController < ApplicationController
  before_action :require_user, :require_organization, :require_organization_owner

  def create
    invitation = Current.organization.invitations.new(params.expect(invitation: [ :email ]))
    if invitation.save
      Rails.event.notify("concourse.membership.invited", organization: Current.organization.slug)
      redirect_to edit_organization_path(Current.organization), notice: t(".invited", email: invitation.email), status: :see_other
    else
      redirect_to edit_organization_path(Current.organization), alert: t(".refused", reason: invitation.errors.full_messages.to_sentence), status: :see_other
    end
  end

  def destroy
    invitation = Current.organization.invitations.find(params[:id])
    invitation.destroy!
    redirect_to edit_organization_path(Current.organization), notice: t(".withdrawn", email: invitation.email), status: :see_other
  end
end
