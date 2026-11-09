# Asks Ajent to revoke a client it minted at /connect. The local binding is
# already revoked when this runs, so Concourse refuses the credential whether
# or not Ajent is reachable; this stops the issuer minting tokens for it.
class RevokeAgentClientJob < ApplicationJob
  queue_as :default

  retry_on Ajent::AgentClients::Unavailable, wait: :polynomially_longer, attempts: 10
  discard_on Ajent::AgentClients::Rejected, Ajent::AgentClients::NotConfigured do |job, error|
    Rails.error.report(error, handled: true, context: { job: job.class.name })
  end

  # Runs after the commit that revoked the binding. A queue failure must not
  # undo or fail that local revocation, so it is reported instead.
  def self.schedule(organization_id, client_id)
    perform_later(organization_id, client_id)
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { job: name, organization_id: organization_id })
  end

  # The organization is the one the client was bound in, for error context.
  def perform(organization_id, client_id)
    Ajent::AgentClients.new.revoke(client_id)
  end
end
