class Api::IdentitiesController < ApiController
  include AgentIdentity

  # Who this token is. The Pi extension reads its agent id and owner here.
  def show
    render json: identity
  end
end
