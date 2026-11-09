class Agent::Connection < ApplicationRecord
  self.table_name = "agent_connections"

  LEASE = 45.seconds
  RETENTION = 1.day
  PRUNE_BATCH = 100
  SESSION_FORMAT = /\A[a-zA-Z0-9._:-]{1,200}\z/

  belongs_to :organization
  belongs_to :agent
  has_many :task_deliveries, foreign_key: :connection_id

  validates :session_id, format: { with: SESSION_FORMAT }

  def self.open!(agent, session_id:)
    raise A2a::Error.new(:invalid_params) unless session_id.is_a?(String) && SESSION_FORMAT.match?(session_id)

    agent.with_lock do
      membership = agent.organization.memberships.find_by(user_id: agent.owner_id)
      raise A2a::Error.new(:task_not_found) unless membership && agent.admitted?

      now = Time.current
      prune!(agent)
      agent.connections.where(organization_id: agent.organization_id, session_id: session_id, closed_at: nil)
        .update_all(closed_at: now)
      create!(id: SecureRandom.uuid, organization: agent.organization, agent: agent, membership_id: membership.id,
        session_id: session_id, observed_at: now, lease_expires_at: now + LEASE,
        limit_at: now + A2a::Stream::LIMIT)
    end
  end

  def active?
    reload
    closed_at.nil? && lease_expires_at > Time.current && limit_at > Time.current && admitted?
  rescue ActiveRecord::RecordNotFound
    false
  end

  def renew!
    with_lock do
      return false unless active?

      now = Time.current
      update!(observed_at: now, lease_expires_at: [ now + LEASE, limit_at ].min)
    end
    true
  end

  def close!
    with_lock { update!(closed_at: Time.current, observed_at: Time.current) unless closed_at }
  end

  # Presence is a transport observation, never a readiness certificate.
  # An expired lease has no evidence of a clean disconnect.
  def self.presence(agent)
    membership = agent.organization.memberships.skip_query_cache!.find_by(user_id: agent.owner_id)
    raise A2a::Error.new(:task_not_found) unless membership && agent.admitted?
    now = Time.current
    scope = agent.connections.where(organization_id: agent.organization_id, membership_id: membership.id).skip_query_cache!
    connected = scope.where(closed_at: nil).where("lease_expires_at > ? AND limit_at > ?", now, now)
      .order(observed_at: :desc).first
    latest = connected || scope.order(observed_at: :desc).first
    state = if connected
      "connected"
    elsif latest&.closed_at && latest.observed_at > now - LEASE
      "disconnected"
    else
      "unknown"
    end
    { "state" => state, "observedAt" => latest&.observed_at&.utc&.iso8601(6),
      "leaseExpiresAt" => latest&.lease_expires_at&.utc&.iso8601(6), "fresh" => connected.present? }
  end

  # Bounded opportunistic cleanup. Referenced observations remain until their
  # task's receipt is purged; deleting them would break publication provenance.
  def self.prune!(agent)
    scope = agent.connections.where(organization_id: agent.organization_id).where("observed_at < ?", Time.current - RETENTION)
      .where("closed_at IS NOT NULL OR lease_expires_at <= ? OR limit_at <= ?", Time.current, Time.current)
      .where.not(id: TaskDelivery.select(:connection_id)) # tenancy-ok: exclusion IDs only; candidates are scoped to this agent
    ids = scope.order(:observed_at).limit(PRUNE_BATCH).pluck(:id)
    scope.where(id: ids).delete_all
  end

  def admitted?
    organization.agents.admitted.exists?(id: agent_id) &&
      organization.memberships.skip_query_cache!.exists?(id: membership_id, user_id: agent.reload.owner_id)
  end
end
