class Current < ActiveSupport::CurrentAttributes
  # The tenant lives here. A web request takes it from the session, an agent
  # request from the calling agent; every scoped query reads it.
  # credential_subject is set only for a person's own sign-in, never for an
  # app's unattended credential: it is what lets an agent act for its owner
  # (Agent::OwnerAuthority).
  attribute :user, :organization, :membership, :agent, :credential_client_id, :credential_subject

  def user=(user)
    super
    refresh_membership
  end

  def organization=(organization)
    super
    refresh_membership
  end

  def organization_owner?
    membership&.owner? || false
  end

  private

  def refresh_membership
    self.membership = user && organization ? user.membership_in(organization) : nil
  end
end
