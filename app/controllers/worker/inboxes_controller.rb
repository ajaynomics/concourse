module Worker
  class InboxesController < ApiController
    def show
      return head :not_found unless params[:agent_id] == Current.agent.id.to_s

      state = params[:state].presence
      if state && !Task::STATES.include?(state)
        return render json: { error: "invalid_state" }, status: :unprocessable_entity
      end

      if Concourse.v3?
        filters = request.query_parameters.slice("pageSize", "pageToken")
        if filters.key?("pageSize")
          value = filters["pageSize"]
          raise A2a::Error.new(:invalid_params) unless value.is_a?(String) && value.match?(/\A[0-9]{1,3}\z/)
          filters["pageSize"] = Integer(value, 10)
        end
        render json: A2a::Exchange.inbox(Current.agent, state: state, filters: filters)
      else
        render json: { tasks: A2a::Exchange.inbox(Current.agent, state: state) }
      end
    rescue A2a::Error
      render json: { error: "invalid_params" }, status: :unprocessable_entity
    end
  end
end
