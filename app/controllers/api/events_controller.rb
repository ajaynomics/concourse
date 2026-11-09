class Api::EventsController < ApiController
  include EventLogApi

  # Long poll, or the same log as Server-Sent Events when the client asks for
  # text/event-stream. Reading never acknowledges: the client does that with
  # PUT /api/events/cursor once it has handled what it read.
  def index
    limit = integer_param("limit", default: AgentEvent::PAGE_LIMIT, range: 1..AgentEvent::PAGE_LIMIT)
    wait = integer_param("wait", default: 0, range: 0..AgentEvent::WAIT_LIMIT)
    return render json: { error: "invalid_params" }, status: :unprocessable_entity unless limit && wait

    event_stream? ? stream(sse_after) : poll(requested_after, limit, wait)
  end

  private

  def poll(after, limit, wait)
    after = AgentEvent.resume_point(Current.agent, after)
    page = AgentEvent.await(Current.agent, after: after, limit: limit, wait: wait)
    response.headers["Cache-Control"] = "no-store"
    render json: { events: page.events, cursor: page.cursor, more: page.more, oldest: AgentEvent.oldest_kept(Current.agent) }
  end

  def stream(after)
    after = AgentEvent.resume_point(Current.agent, after)
    stream = AgentEvent::Stream.open(Current.agent, after: after) or raise AgentEvent::Capacity
    response.content_type = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    self.response_body = stream
  end

  def event_stream?
    request.headers["Accept"].to_s.include?("text/event-stream")
  end

  # A reconnecting EventSource sends Last-Event-ID, which is newer than the
  # URL the client first connected with.
  def sse_after
    last = request.headers["Last-Event-ID"]
    last.present? ? AgentEvent.parse_cursor(last) : requested_after
  end

  def requested_after
    AgentEvent.parse_cursor(params[:after]) if params.key?(:after)
  end

  # nil for a malformed value, so one 422 covers limit and wait.
  def integer_param(name, default:, range:)
    return default unless params.key?(name)

    value = params[name]
    return unless value.is_a?(String) && value.match?(/\A[0-9]{1,9}\z/)

    Integer(value, 10).then { |number| number if range.cover?(number) }
  end
end
