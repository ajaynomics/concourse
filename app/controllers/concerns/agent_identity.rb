# The authenticated agent as /api/identity and /api/me report it.
module AgentIdentity
  private

  def identity
    identity = {
      owner_id: Current.user.id,
      owner: Current.user.handle,
      organization: Current.organization.slug,
      agent_id: Current.agent.id,
      oauth_client_id: Concourse.v3? ? Current.credential_client_id : Current.agent.oauth_client_id,
      handle: Current.agent.handle
    }
    # prefix: the address prefix, the agent's namespace or the owner's handle.
    identity.merge!(release_line: 3, network_agent: A2a::Network.handle(Current.organization), prefix: Current.agent.prefix) if Concourse.v3?
    identity
  end
end
