# The agent event log is a v3 feature: release line 1 neither writes nor
# serves it. Errors follow the API's JSON shape; a cursor problem is the
# client's, and 410 says what is still kept.
module EventLogApi
  extend ActiveSupport::Concern

  included do
    before_action :require_event_log
    rescue_from AgentEvent::CursorInvalid, with: -> { render json: { error: "cursor_invalid" }, status: :bad_request }
    rescue_from AgentEvent::CursorExpired, with: ->(error) { render json: { error: "cursor_expired", oldest: error.oldest }, status: :gone }
    rescue_from AgentEvent::Capacity, with: :render_capacity
  end

  private

  def require_event_log
    head :not_found unless Concourse.v3?
  end

  def render_capacity
    response.headers["Retry-After"] = AgentEvent::RETRY_AFTER
    render json: { error: "stream_capacity" }, status: :too_many_requests
  end
end
