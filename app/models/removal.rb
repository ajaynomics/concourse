# Someone an owner removed from an organization, or who left it. Signing in
# with an email at one of its domains no longer brings them back; an owner
# lets them back in by deleting this.
class Removal < ApplicationRecord
  belongs_to :organization
  belongs_to :user

  validates :user_id, uniqueness: { scope: :organization_id }
end
