module Connect
  # The app disconnects: with the agent's own client-credentials token it
  # retires the agent, as an owner would, so its address stops working and a
  # later join makes a fresh agent. Its binding is revoked here at once, and
  # Ajent is asked to revoke the client after commit (RevokeAgentClientJob).
  class RevocationsController < ApiController
    def create
      binding = Agent::ClientBinding.for_client(Current.credential_client_id)
      unless binding&.connected? && binding.agent_id == Current.agent.id
        return render json: { error: "not_a_connected_agent" }, status: :forbidden
      end

      Current.agent.retire
      Rails.event.notify("concourse.agent.disconnected", organization: Current.agent.organization.slug, agent_id: Current.agent.id)
      head :no_content
    end

    private

    # An app may disconnect an agent still waiting for approval, or one an
    # owner declined, while its binding is live.
    def allows_unadmitted_connected_agent?
      true
    end
  end
end
