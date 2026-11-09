class User < ApplicationRecord
  # Raised when the identity provider verified a sign-in that carries no
  # subject. No User row is created in that case.
  class UnauthorizedIdentity < StandardError; end

  SYSTEM_HANDLE = "concourse"
  HANDLE_FORMAT = /\A[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?\z/
  # concourse is the system user; assigning it to a person fails validation.
  # The rest are route and infrastructure names, not people.
  RESERVED_HANDLES = %w[concourse a2a admin agents api auth join mcp tasks up www].freeze

  has_many :agents, foreign_key: :owner_id, inverse_of: :owner, dependent: :destroy
  has_many :push_subscriptions, dependent: :delete_all
  has_many :memberships, dependent: :destroy
  has_many :removals, dependent: :delete_all
  has_many :join_requests, dependent: :delete_all
  has_many :organizations, through: :memberships

  validates :handle, presence: true, uniqueness: true, format: { with: HANDLE_FORMAT }
  validates :ajent_sub, uniqueness: true, allow_nil: true
  validate :subject_matches_kind
  validate :handle_is_not_a_namespace, if: :will_save_change_to_handle?

  def self.system
    find_or_create_by!(handle: SYSTEM_HANDLE) do |user|
      user.name = "Concourse"
    end
  end

  # Signing in creates the account; membership is a separate question. An
  # email the provider vouches for joins every organization that claims its
  # domain. An unverified one joins nothing, or anyone could claim a domain
  # by typing it.
  def self.upsert_from_identity!(subject:, user_info:)
    raise UnauthorizedIdentity, "missing subject" if subject.blank?

    user = find_or_initialize_by(ajent_sub: subject.to_s)
    user.email = string_from(user_info, "email") || user.email
    user.name = string_from(user_info, "name").presence || user.name || user.email
    user.email_verified = verified_email?(user_info)
    # A shared card is the handle. A user who already has an agent keeps
    # the handle they were given on first sight, placeholder or not.
    if user.handle.blank? || (user.placeholder_handle? && user.agents.none?)
      user.handle = available_handle(preferred_handle(email: user.email, sub: subject), except: user)
    end
    user.save!
    user.join_organizations if verified_email?(user_info)
    user
  end

  # First sight of an agent token, before the person has signed in on the web.
  # Introspection username is the user's email; the handle is that local part,
  # the same derivation web sign-in uses. Without it, a stable placeholder
  # derived from sub. A user who already has an agent is never renamed.
  def self.find_or_create_from_subject!(ajent_sub:, email: nil, name: nil)
    user = find_or_initialize_by(ajent_sub: ajent_sub.to_s)
    if user.new_record?
      user.email = email
      user.name = name
      user.handle = available_handle(preferred_handle(email: email, sub: ajent_sub))
      user.save!
    else
      user.email = email if user.email.blank? && email.present?
      user.name = name if user.name.blank? && name.present?
      user.save! if user.changed?
    end
    user
  end

  def self.handle_from_email(email)
    return if email.blank? || !email.to_s.include?("@")

    sanitize_handle(email.to_s.split("@", 2).first)
  end

  def self.handle_from_sub(sub)
    sanitize_handle("sub-#{sub}")
  end

  # An invitation is an owner's approval. A claimed domain is not: an
  # organization that approves members gets a request instead of a member.
  def join_organizations
    Invitation.where(email: email.to_s.strip.downcase).includes(:organization).each { |invitation| invitation.accept(self) } # tenancy-ok: invitations addressed to this verified email
    Organization.claiming_email_domain(email_domain).each do |organization|
      next if organizations.include?(organization) || organization.removals.exists?(user: self)

      if organization.approves_members?
        request = organization.join_requests.find_or_create_by!(user: self)
        Rails.event.notify("concourse.membership.requested", user_id: id, organization: organization.slug) if request.previously_new_record?
      else
        memberships.create!(organization: organization)
        Rails.event.notify("concourse.membership.joined", user_id: id, organization: organization.slug)
      end
    end
  end

  def email_domain
    email.to_s.split("@", 2).second.to_s.downcase.presence
  end

  # The domain this person has proved, at their last web sign-in, that they
  # hold an address at.
  def verified_email_domain
    email_domain if email_verified?
  end

  def membership_in(organization)
    memberships.find_by(organization: organization)
  end

  # The web's first organization and the legacy agent default: the oldest
  # membership. V3 enrollment never uses this to resolve ambiguity.
  def first_organization
    memberships.order(:created_at, :id).first&.organization
  end

  def placeholder_handle?
    handle.present? && ajent_sub.present? && handle == self.class.handle_from_sub(ajent_sub)
  end

  def system?
    handle == SYSTEM_HANDLE && ajent_sub.blank?
  end

  def to_s
    name.presence || email.presence || handle
  end

  # OIDC Core §5.1 makes email_verified a boolean. Some providers send the
  # string, which means the same thing.
  def self.verified_email?(user_info)
    [ true, "true" ].include?((user_info || {})["email_verified"])
  end

  def self.preferred_handle(email:, sub:)
    handle_from_email(email) || handle_from_sub(sub)
  end

  def self.sanitize_handle(value)
    cleaned = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    cleaned = "user" if cleaned.blank?
    cleaned = cleaned[0, 40].gsub(/-+\z/, "")
    cleaned.presence || "user"
  end

  def self.available_handle(candidate, except: nil)
    base = sanitize_handle(candidate)
    handle = base
    suffix = 2
    scope = except&.persisted? ? where.not(id: except.id) : all
    while reserved_handle?(handle) || scope.exists?(handle: handle) || Namespace.exists?(name: handle) # tenancy-ok: prefixes are one space across organizations
      handle = sanitize_handle("#{base}-#{suffix}")
      suffix += 1
    end
    handle
  end

  def self.reserved_handle?(handle)
    RESERVED_HANDLES.include?(handle)
  end

  def self.string_from(user_info, key)
    info = user_info || {}
    info[key].presence || info[key.to_sym].presence
  end

  private_class_method :verified_email?, :preferred_handle, :sanitize_handle, :available_handle, :reserved_handle?, :string_from

  private

  # A namespace and a person's handle are both address prefixes.
  def handle_is_not_a_namespace
    errors.add(:handle, :taken) if Namespace.exists?(name: handle) # tenancy-ok: prefixes are one space across organizations
  end

  def subject_matches_kind
    if handle == SYSTEM_HANDLE
      errors.add(:ajent_sub, "must be blank") if ajent_sub.present?
    elsif ajent_sub.blank?
      errors.add(:ajent_sub, "must be present")
    end
  end
end
