# An owner inviting someone by email. The person joins at their next sign-in
# with that address verified, whatever its domain.
class Invitation < ApplicationRecord
  belongs_to :organization

  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { scope: :organization_id }

  def accept(user)
    transaction do
      organization.memberships.create!(user: user) unless organization.users.include?(user)
      organization.removals.where(user: user).delete_all
      organization.join_requests.where(user: user).delete_all
      destroy!
    end
  end
end
