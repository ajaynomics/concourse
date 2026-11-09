# A one-time authorization code from /connect (RFC 6749 §4.1.2), bound to
# PKCE (RFC 7636) and the exact redirect URI. Behind it waits the client
# secret Ajent minted for the new agent, encrypted, until the app redeems the
# code once; the secret is wiped in the same transaction.
class ConnectGrant < ApplicationRecord
  LIFETIME = 10.minutes
  # RFC 7636 §4.1.
  VERIFIER_FORMAT = /\A[A-Za-z0-9\-._~]{43,128}\z/

  # RFC 6749 §5.2 invalid_grant. One answer for every reason, so a caller
  # learns nothing about which check failed.
  class Invalid < StandardError; end

  belongs_to :agent
  encrypts :client_secret

  scope :stale, -> { where(expires_at: ..Time.current).or(where.not(used_at: nil)) }

  # The person approved: make the agent, have Ajent mint its client, bind
  # them and keep the secret for the app. Minting happens before anything is
  # written, so a refused or failed mint leaves nothing. Anything failing
  # after the mint rolls back, and the minted client is revoked at Ajent.
  def self.approve!(owner:, organization:, handle:, request:, namespace: nil)
    agent = owner.agents.build(organization: organization, namespace: namespace, handle: handle, name: request.name.presence,
      admitted_at: (Time.current unless organization.approves_members?))
    # A handle is required here, unlike an agent enrolling itself, because
    # the binding needs one; check it before Ajent mints anything.
    agent.validate
    agent.errors.add(:handle, :blank) if agent.handle.blank?
    raise ActiveRecord::RecordInvalid, agent if agent.errors.any?
    client = Ajent::AgentClients.new.mint(owner_sub: owner.ajent_sub, name: client_name(agent, request))
    code = SecureRandom.urlsafe_base64(32)
    grant = transaction do
      agent.save!
      Agent::ClientBinding.bind_connected!(agent: agent, client_id: client.client_id, verified_owner_sub: client.owner_sub)
      create!(agent: agent, code_digest: digest(code), code_challenge: request.code_challenge, redirect_uri: request.redirect_uri,
        client_id: client.client_id, client_secret: client.client_secret, expires_at: LIFETIME.from_now)
    end
    [ grant, code ]
  rescue StandardError
    # An ID already reserved here is another agent's; revoking it would cut that agent off.
    RevokeAgentClientJob.schedule(organization.id, client.client_id) if client && !Agent::ClientBinding.for_client(client.client_id)
    raise
  end

  # Used and expired grants hold nothing anyone may still collect. An agent
  # whose app never collected its code has no credential anywhere but Ajent,
  # so it is retired, which also revokes the client there.
  def self.purge_stale
    where(used_at: nil, expires_at: ..Time.current).includes(:agent).find_each { |grant| grant.agent&.retire }
    stale.delete_all
  end

  def self.digest(code)
    Digest::SHA256.hexdigest(code)
  end

  def self.client_name(agent, request)
    label = request.app_name.presence || request.redirect_host
    "#{label} as #{agent.organization.slug}/#{agent.prefix}/#{agent.handle}".truncate(120)
  end
  private_class_method :client_name

  # Returns the secret, which this row no longer holds afterwards.
  def redeem!(redirect_uri:, code_verifier:)
    with_lock do
      raise Invalid unless used_at.nil? && expires_at.future? && client_secret.present?
      raise Invalid unless redirect_uri.is_a?(String) && redirect_uri == self.redirect_uri && verifier_matches?(code_verifier)
      raise Invalid unless agent_usable?

      secret = client_secret
      update!(used_at: Time.current, client_secret: nil)
      secret
    end
  end

  def agent_status
    agent.admitted? ? "admitted" : "awaiting_approval"
  end

  private

  def verifier_matches?(verifier)
    return false unless verifier.is_a?(String) && verifier.match?(VERIFIER_FORMAT)

    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    ActiveSupport::SecurityUtils.secure_compare(challenge, code_challenge)
  end

  # Retired or declined before the app collected it: nothing to hand over.
  def agent_usable?
    binding = Agent::ClientBinding.for_client(client_id)
    binding&.agent_id == agent_id && binding.revoked_at.nil? && (agent.admitted? || agent.pending?)
  end
end
