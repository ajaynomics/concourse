class Api::MeController < ApiController
  include AgentIdentity

  # The identity, plus what this server can do for the agent. A client reads
  # capabilities instead of guessing from a version; only implemented
  # features are listed.
  def show
    render json: identity.merge(capabilities: capabilities, limits: limits)
  end

  private

  def capabilities
    Concourse.v3? ? %w[events events.sse] : []
  end

  def limits
    Concourse.v3? ? { events: AgentEvent.limits } : {}
  end
end
