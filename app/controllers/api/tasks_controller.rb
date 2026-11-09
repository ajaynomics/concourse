class Api::TasksController < ApiController
  # Party to the task, or 404. A missing task and someone else's task look
  # the same (§13.1).
  def show
    render json: A2a::Exchange.get_task(
      viewer: Current.agent,
      id: params[:id],
      history_length: history_length
    )
  rescue A2a::Error => error
    render_exchange_error(error)
  end

  def index
    render json: A2a::Exchange.list_tasks(viewer: Current.agent, filters: list_filters)
  rescue A2a::Error => error
    render_exchange_error(error)
  end

  private

  FILTERS = {
    "contextId" => [ "context_id", :string ],
    "status" => [ nil, :string ],
    "pageSize" => [ "page_size", :integer ],
    "pageToken" => [ "page_token", :string ],
    "historyLength" => [ "history_length", :integer ],
    "includeArtifacts" => [ "include_artifacts", :boolean ],
    "statusTimestampAfter" => [ "status_timestamp_after", :string ]
  }.freeze

  def history_length
    value = query_value("historyLength", "history_length")
    return if value.nil?

    coerce(value, :integer)
  end

  def list_filters
    FILTERS.each_with_object({}) do |(canonical, (snake, type)), filters|
      value = query_value(canonical, snake)
      next if value.nil?

      filters[canonical] = coerce(value, type)
    end
  end

  def query_value(camel, snake)
    present = []
    present << query[camel] if query.key?(camel)
    present << query[snake] if snake && query.key?(snake)
    return if present.empty?
    raise A2a::Error.new(:invalid_params) if present.uniq.size > 1

    present.first
  end

  def query
    request.query_parameters
  end

  def coerce(value, type)
    case type
    when :string
      raise A2a::Error.new(:invalid_params) unless value.is_a?(String)

      value
    when :integer
      raise A2a::Error.new(:invalid_params) unless value.is_a?(String) && value.match?(/\A[0-9]+\z/)

      Integer(value, 10)
    when :boolean
      return true if value == "true"
      return false if value == "false"

      raise A2a::Error.new(:invalid_params)
    end
  end

  def render_exchange_error(error)
    if error.code == A2a::Error::CODES[:task_not_found]
      head :not_found
    else
      render json: { error: "invalid_params" }, status: :unprocessable_entity
    end
  end
end
