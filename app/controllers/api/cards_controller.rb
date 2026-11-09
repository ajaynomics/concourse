class Api::CardsController < ApiController
  def update
    payload = json_object
    return head :bad_request unless payload

    render json: A2a::Exchange.update_card(Current.agent, **card_attributes(payload))
  rescue JSON::ParserError
    head :bad_request
  rescue A2a::Error
    render json: { error: "invalid_params" }, status: :unprocessable_entity
  end

  private

  def json_object
    raw = request.raw_post
    parsed = raw.blank? ? {} : JSON.parse(raw)
    parsed if parsed.is_a?(Hash)
  end

  def card_attributes(payload)
    {
      handle: payload["handle"],
      name: payload["name"],
      description: payload["description"],
      skills: payload.key?("skills") ? payload["skills"] : nil,
      harness: payload["harness"],
      projects: payload.key?("projects") ? payload["projects"] : nil
    }
  end
end
