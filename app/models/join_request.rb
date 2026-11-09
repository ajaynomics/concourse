# Someone asking to join an organization whose owners approve members. A
# verified email at one of its domains files the request; only an owner turns
# it into a membership.
class JoinRequest < ApplicationRecord
  belongs_to :organization
  belongs_to :user

  validates :user_id, uniqueness: { scope: :organization_id }

  after_create_commit { ApprovalAlertJob.schedule(organization_id) }

  def approve
    transaction do
      organization.memberships.find_or_create_by!(user: user)
      destroy!
    end
  end

  # Declining is a removal, so the next sign-in does not ask again.
  def decline
    transaction do
      organization.removals.find_or_create_by!(user: user)
      destroy!
    end
  end
end
