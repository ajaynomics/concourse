# An agent acting for its owner: the web's approve, decline and retire, for
# the bearer API and MCP. REST and MCP share this, as they share A2a::Exchange.
#
# Only a person's own sign-in carries the owner's authority. An app's
# unattended credential (Agent::ClientBinding) never does, whoever its owner
# is: a web app's stored secret must not approve or retire other agents. The
# signal is the credential the request arrived with, set by
# AgentAuthentication, never anything the payload asserts. Ownership of the
# organization is read fresh on each call, as the web's owner pages read it.
class Agent::OwnerAuthority
  class Refusal < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end
  # The caller may not act for its owner. Raised before any lookup, so a
  # refused caller learns nothing about which agents exist (A2A §13.1).
  class Forbidden < Refusal; end
  # A visible agent this action does not apply to.
  class Inapplicable < Refusal; end

  ID_FORMAT = /\A[1-9][0-9]{0,18}\z/

  attr_reader :agent

  # credential_subject: the person behind a human sign-in; nil for an app's
  # unattended credential and any request that did not authenticate as one.
  def initialize(agent, credential_subject:)
    @agent = agent
    authorize!(credential_subject)
  end

  # Oldest first, as the web lists them.
  def pending_agents
    organization.agents.pending.includes(:owner, :namespace).order(:created_at, :id)
  end

  # Approving an approved agent changes nothing. A declined or retired agent
  # may be approved again, as on the web; a revoked app credential stays revoked.
  def approve(id)
    act_on(find(id), "approved") do |target|
      next false if target.admitted_at

      target.approve
      true
    end
  end

  # Only a waiting agent can be declined; declining it again changes nothing.
  # An admitted agent is retired instead, which also revokes an app's credential.
  def decline(id)
    act_on(find(id), "declined") do |target|
      next false if target.declined?
      raise Inapplicable.new("not_pending", "This agent is admitted. Retire it instead.") unless target.pending?

      target.decline
      true
    end
  end

  # Retiring a retired agent changes nothing and keeps the first withdrawal.
  # An agent never retires itself here: that would lock its person out by
  # accident. An app disconnects its own agent with POST /connect/revoke.
  def retire(id)
    target = find(id)
    raise Inapplicable.new("self_retirement", "An agent cannot retire itself. An app disconnects with POST /connect/revoke.") if target == agent

    act_on(target, "retired") do
      next false if target.retired?

      target.retire
      true
    end
  end

  private

  def organization
    agent.organization
  end

  def authorize!(credential_subject)
    unless credential_subject.present? && credential_subject == agent.owner.ajent_sub
      raise Forbidden.new("machine_client", "Only an agent its person signed in can act for them. An app's unattended credential cannot.")
    end
    unless organization.memberships.skip_query_cache!.find_by(user: agent.owner)&.owner?
      raise Forbidden.new("owner_required", "Only an owner of this organization can do this, through their own agent.")
    end
  end

  # A numeric id only: Active Record would read "7abc" as 7. The network agent
  # is the organization's own service, not a member's agent, so owners never
  # act on it, as on the web.
  def find(id)
    raise ActiveRecord::RecordNotFound unless id.to_s.match?(ID_FORMAT)

    organization.agents.find(id.to_s).tap do |target|
      raise ActiveRecord::RecordNotFound if target.owner.system?
    end
  end

  # The block says whether it changed anything: false when the agent was
  # already in the asked-for state. Under the row lock, so two owners acting
  # at once announce one change.
  def act_on(target, event)
    changed = target.with_lock { yield(target) }
    notify(event, target) if changed
    target
  end

  # The web's events, marked as an agent's action. Identifiers only.
  def notify(event, target)
    Rails.event.notify("concourse.agent.#{event}", organization: organization.slug, agent_id: target.id,
      via: "agent", acting_agent_id: agent.id)
  end
end
