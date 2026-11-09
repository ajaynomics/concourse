class Agent::ClientBinding < ApplicationRecord
  # A reservation is global OAuth identity metadata, not a second agent directory.
  # Keep it when the agent disappears so a surviving token can never acquire
  # another agent through reuse of its client ID (RFC 7662 section 2.2).
  belongs_to :agent, optional: true, inverse_of: :client_binding
  attr_accessor :verified_owner_sub

  # operator: bound by hand after inspecting the issuer (bind!). connect: Ajent
  # minted the client when a signed-in member approved an app (bind_connected!).
  PROVENANCES = %w[operator connect].freeze

  validates :client_id, presence: true, uniqueness: true, length: { maximum: 255 }, format: { with: /\A\S+\z/ }
  validates :agent_id, uniqueness: true, allow_nil: true
  validates :provenance, inclusion: { in: PROVENANCES }
  validate :verified_existing_agent, on: :create
  validate :immutable_reservation, on: :update
  before_validation :remember_identity, on: :create
  before_destroy { throw :abort }
  after_update_commit :revoke_at_issuer, if: -> { connected? && saved_change_to_revoked_at? }

  def self.for_client(client_id)
    return unless client_id.is_a?(String) && client_id.present?

    all.skip_query_cache!.find_by(client_id: client_id)
  end

  def self.machine_payload?(payload)
    payload["sub"].blank? || for_client(payload["client_id"]).present?
  end

  def self.organization_allowed?(organization)
    organization.machine_clients_allowed?
  end

  def self.bind!(agent:, client_id:, verified_owner_sub:)
    create!(agent: agent, client_id: client_id, verified_owner_sub: verified_owner_sub)
  end

  # The one sanctioned binding made over HTTP: a signed-in member approved an
  # app at /connect, and Ajent minted the client and named its owner. The agent
  # may still await an owner's approval; it works once approved.
  def self.bind_connected!(agent:, client_id:, verified_owner_sub:)
    create!(agent: agent, client_id: client_id, verified_owner_sub: verified_owner_sub, provenance: "connect")
  end

  def connected?
    provenance == "connect"
  end

  def admitted_agent!
    # Query-cache bypass alone does not refresh a retained model or association.
    # The organization is read fresh too, so an owner turning machine clients
    # off refuses this credential at its next request.
    record = Agent.uncached { reload.agent.tap { |agent| agent&.organization } }
    matches = record && record.owner_id == bound_owner_id && record.organization_id == bound_organization_id
    unless revoked_at.nil? && matches && record.handle.present? && self.class.organization_allowed?(record.organization)
      raise Ajent::Introspection::Rejected
    end
    # A good credential for an agent an owner has not approved is a 403 that
    # says so, not invalid_token, which clients answer by signing in again.
    unless record.admitted?
      refusal = record.admission_refusal
      raise Ajent::Introspection::Rejected if refusal == Agent::Unadmitted

      raise refusal.new(client_binding: self)
    end
    record
  end

  def revoke!
    with_lock { update!(revoked_at: Time.current) if revoked_at.nil? }
  end

  private

  def remember_identity
    self.bound_owner_id = agent&.owner_id
    self.bound_organization_id = agent&.organization_id
  end

  def revoke_at_issuer
    RevokeAgentClientJob.schedule(bound_organization_id, client_id)
  end

  def verified_existing_agent
    # A connected agent may wait for approval, but its owner is a member now.
    admissible = agent&.admitted? ||
      (connected? && agent&.pending? && agent.owner.memberships.exists?(organization_id: agent.organization_id))
    unless agent&.persisted? && agent.handle.present? && admissible && self.class.organization_allowed?(agent.organization)
      errors.add(:agent, "must be an existing named admitted agent in an enabled organization")
    end
    unless verified_owner_sub.is_a?(String) && verified_owner_sub.present? && verified_owner_sub == agent&.owner&.ajent_sub
      errors.add(:verified_owner_sub, "must match the independently verified issuer application owner")
    end
    if Agent.exists?(oauth_client_id: client_id) # tenancy-ok: a globally reserved client must not overlap any user registration
      errors.add(:client_id, "is already a user registration")
    end
  end

  def immutable_reservation
    %w[client_id agent_id bound_owner_id bound_organization_id provenance].each do |attribute|
      errors.add(attribute, "cannot change") if will_save_change_to_attribute?(attribute)
    end
    errors.add(:revoked_at, "cannot be cleared or changed") if revoked_at_in_database.present? && will_save_change_to_revoked_at?
  end
end
