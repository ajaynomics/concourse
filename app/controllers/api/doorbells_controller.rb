class Api::DoorbellsController < ApiController
  def show
    session_id = request.headers["Concourse-Session-Id"]
    stream = session_id ? Agent::Doorbell.open(Current.agent, session_id: session_id) : Agent::Doorbell.open(Current.agent)
    unless stream
      response.headers["Retry-After"] = "30"
      return render json: { error: "doorbell_capacity" }, status: :too_many_requests
    end

    response.content_type = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    self.response_body = stream
  rescue A2a::Error
    render json: { error: "invalid_session" }, status: :unprocessable_entity
  end
end
