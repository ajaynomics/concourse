# The calling agent's webhook. PUT creates or replaces it, which is also how
# the token is rotated. The token is write-only: no response includes it.
class Api::PushConfigsController < ApiController
  def show
    config = Current.agent.push_config
    config ? render(json: config) : head(:not_found)
  end

  def update
    config = Current.agent.push_config || Current.agent.build_push_config
    if config.update(params.permit(:url, :token))
      render json: config
    else
      render json: { error: "invalid_params", details: config.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    Current.agent.push_config&.destroy
    head :no_content
  end
end
