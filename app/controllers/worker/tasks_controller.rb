module Worker
  # Recipient only. Anyone else, including the caller, gets 404 so the
  # response does not reveal that the task exists (§13.1).
  class TasksController < ApiController
    before_action :require_json_object

    def create_message
      task = apply(parts: parts_from(payload))
      render json: A2a::Serializer.message(task.messages.order(created_at: :desc, message_id: :desc).first)
    rescue A2a::Error
      head :not_found
    end

    def update
      if payload.key?("artifacts")
        raise A2a::Error.new(:invalid_params) unless Concourse.v3? && payload["artifacts"].is_a?(Array) && !payload.key?("artifact")
      end
      artifact = payload["artifact"]
      if payload.key?("artifact") && Concourse.v3?
        raise A2a::Error.new(:invalid_params) unless artifact.is_a?(Hash)
      end
      artifact = { parts: parts_from(artifact), name: artifact["name"], description: artifact["description"] } if artifact && !Concourse.v3?
      freshness = payload.key?("expected_caller_input") ? { expected_caller_input: payload["expected_caller_input"] } : {}
      task = apply(parts: message_parts, state: payload["state"], artifact: artifact, artifacts: payload["artifacts"], **freshness)
      result = A2a::Serializer.task(task)
      result["delivery"] = task.task_deliveries.find_by!(id: payload.dig("delivery", "id")).to_h if Concourse.v3? && !payload["delivery"].nil?
      render json: result
    rescue A2a::Exchange::StaleReply
      render json: { error: "stale_reply" }, status: :conflict
    rescue A2a::Error => error
      if error.code == A2a::Error::CODES[:task_not_found]
        head :not_found
      else
        render json: { error: "invalid_transition" }, status: :unprocessable_entity
      end
    end

    def create_artifact
      artifact = Concourse.v3? ? payload.except("delivery") : {
        parts: parts_from(payload),
        name: payload["name"],
        description: payload["description"]
      }
      task = apply(artifact: artifact)
      render json: A2a::Serializer.artifact(task.artifacts.order(created_at: :desc, artifact_id: :desc).first)
    rescue A2a::Error
      head :not_found
    end

    private

    def apply(**kwargs)
      A2a::Exchange.reply(agent: Current.agent, task_id: params[:task_id], delivery: payload["delivery"], **kwargs)
    end

    def require_json_object
      raw = request.raw_post
      @payload = raw.blank? ? {} : JSON.parse(raw)
      head :bad_request unless @payload.is_a?(Hash)
    rescue JSON::ParserError
      head :bad_request
    end

    def payload
      @payload
    end

    def message_parts
      message = payload["message"]
      return if message.blank?

      parts_from(message)
    end

    def parts_from(source)
      raw = source.is_a?(Hash) ? source["parts"] : nil
      raise A2a::Error.new(:invalid_params) unless raw.is_a?(Array) && raw.any?

      raw
    end
  end
end
