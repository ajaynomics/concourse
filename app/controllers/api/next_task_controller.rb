class Api::NextTaskController < ApiController
  # Same 45 second cap and waiter cap as the MCP tool. An optional wait may
  # only shorten that cap; it cannot outlive it.
  def show
    wait = requested_wait
    payload = if wait.nil?
      A2a::Exchange.next_task_payload(Current.agent)
    else
      A2a::Exchange.with_limits(inbox: wait) { A2a::Exchange.next_task_payload(Current.agent) }
    end
    render json: payload
  rescue A2a::Error
    render json: { error: "invalid_params" }, status: :unprocessable_entity
  end

  private

  def requested_wait
    return unless query.key?("wait")

    value = coerce_wait(query["wait"])
    raise A2a::Error.new(:invalid_params) unless value.between?(0, A2a::Exchange::INBOX_WAIT)

    value
  end

  def coerce_wait(value)
    raise A2a::Error.new(:invalid_params) unless value.is_a?(String) && value.match?(/\A[0-9]+\z/)

    Integer(value, 10)
  end

  def query
    request.query_parameters
  end
end
