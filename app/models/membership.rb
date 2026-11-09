class Membership < ApplicationRecord
  # Owners keep the organization's name, email domains, and member list.
  # Members do everything else.
  ROLES = %w[owner member].freeze

  belongs_to :user
  belongs_to :organization

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :organization_id }
  validate :organization_keeps_an_owner

  # Only an owner can remove anyone, so an organization that loses its last
  # owner has nobody who can give it one back. destroyed_by_association
  # exempts the cascade when the user or the organization itself is deleted.
  before_destroy :ensure_an_owner_remains, unless: :destroyed_by_association

  scope :owners, -> { where(role: "owner") }

  def owner?
    role == "owner"
  end

  # Asked by the settings page, so it never offers a removal that would be
  # refused.
  def last_owner?
    owner? && other_owners.none?
  end

  # The lock keeps two simultaneous removals from each seeing the other owner
  # still in place and leaving nobody. The removal is recorded, so signing in
  # again does not undo it.
  def remove
    with_lock do
      destroy && organization.removals.find_or_create_by!(user: user)
    end
  end

  private

  def other_owners
    organization.memberships.owners.where.not(id: id)
  end

  def organization_keeps_an_owner
    return unless persisted? && role_changed?(from: "owner")

    errors.add(:role, :last_owner) if other_owners.none?
  end

  # role_in_database, not role: a refused demotion leaves "member" on this
  # object while the row still says "owner".
  def ensure_an_owner_remains
    return unless role_in_database == "owner"
    return if other_owners.any?

    errors.add(:base, :last_owner)
    throw :abort
  end
end
