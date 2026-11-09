require "base64"

module A2a
  # Raw wire validation precedes ID translation or record import. These are
  # ProtoJSON SendMessageResponse unions (§3.1.1, §9.4), not an SDK's internal
  # Task|Message union. A malformed post-send response proves no non-delivery.
  class NativeResult
    class Invalid < StandardError; end

    STATES = %w[
      TASK_STATE_SUBMITTED TASK_STATE_WORKING TASK_STATE_INPUT_REQUIRED
      TASK_STATE_AUTH_REQUIRED TASK_STATE_COMPLETED TASK_STATE_CANCELED
      TASK_STATE_FAILED TASK_STATE_REJECTED
    ].freeze
    OUTPUT_LIMIT = 2.megabytes

    attr_reader :task, :message, :error

    def self.parse(body, rpc_id:)
      raise Invalid unless body.is_a?(String) && body.bytesize <= OUTPUT_LIMIT
      body = body.dup.force_encoding(Encoding::UTF_8)
      raise Invalid unless body.valid_encoding?
      envelope = JSON.parse(body)
      raise Invalid unless envelope.is_a?(Hash) && envelope["jsonrpc"] == "2.0" && envelope["id"] == rpc_id
      raise Invalid unless envelope.key?("result") ^ envelope.key?("error")

      if envelope.key?("error")
        error = envelope["error"]
        raise Invalid unless error.is_a?(Hash) && error["code"].is_a?(Integer) && error["message"].is_a?(String)
        # Known ID-free ErrorInfo refusals are safe to preserve (§5.4).
        # Unknown detail schemas still fail closed rather than leak IDs.
        safe_error_details!(error["data"]) if error.key?("data")
        new(error: error.slice("code", "message", "data"))
      else
        result = envelope["result"]
        raise Invalid unless result.is_a?(Hash) && (result.key?("task") ^ result.key?("message"))
        if result.key?("task")
          validate_task!(result["task"])
          new(task: result["task"])
        else
          validate_message!(result["message"])
          new(message: result["message"])
        end
      end
    rescue JSON::ParserError, TypeError, ArgumentError
      raise Invalid
    end

    # GetTask/CancelTask (§3.1.3/§3.1.5) return a Task directly, unlike
    # SendMessageResponse. Reuse envelope validation, not send-union coercion.
    def self.parse_task(body, rpc_id:)
      raise Invalid unless body.is_a?(String) && body.bytesize <= OUTPUT_LIMIT
      body = body.dup.force_encoding(Encoding::UTF_8)
      raise Invalid unless body.valid_encoding?
      envelope = JSON.parse(body)
      raise Invalid unless envelope.is_a?(Hash) && envelope["jsonrpc"] == "2.0" && envelope["id"] == rpc_id
      raise Invalid unless envelope.key?("result") ^ envelope.key?("error")
      return parse(body, rpc_id: rpc_id) if envelope.key?("error")

      validate_task!(envelope["result"])
      new(task: envelope["result"])
    rescue JSON::ParserError, TypeError, ArgumentError
      raise Invalid
    end

    def self.validate_task!(task)
      object!(task)
      string!(task["id"])
      string!(task["contextId"]) if task.key?("contextId")
      status = task["status"]
      object!(status)
      raise Invalid unless STATES.include?(status["state"])
      if status.key?("timestamp")
        string!(status["timestamp"])
        Time.iso8601(status["timestamp"])
      end
      validate_message!(status["message"], task: task, client_echo: true) if status.key?("message")
      list!(task, "history") { |message| validate_message!(message, task: task, client_echo: true) }
      list!(task, "artifacts") { |artifact| validate_artifact!(artifact) }
      artifact_ids = Array(task["artifacts"]).map { |artifact| artifact["artifactId"] }
      raise Invalid unless artifact_ids.uniq.size == artifact_ids.size
      metadata!(task)
      task
    rescue ArgumentError
      raise Invalid
    end

    def self.validate_message!(message, task: nil, client_echo: false)
      object!(message)
      string!(message["messageId"])
      raise Invalid unless %w[ROLE_USER ROLE_AGENT].include?(message["role"])
      optional_associations = client_echo && message["role"] == "ROLE_USER"
      string!(message["contextId"]) unless optional_associations && !message.key?("contextId")
      string!(message["taskId"]) if message.key?("taskId")
      if task
        raise Invalid if message.key?("taskId") && message["taskId"] != task["id"]
        raise Invalid if task.key?("contextId") && message.key?("contextId") && message["contextId"] != task["contextId"]
      end
      parts!(message["parts"])
      metadata!(message)
      strings!(message, "extensions")
      strings!(message, "referenceTaskIds")
      message
    end

    def self.validate_artifact!(artifact)
      object!(artifact)
      string!(artifact["artifactId"])
      parts!(artifact["parts"])
      metadata!(artifact)
      strings!(artifact, "extensions")
      string!(artifact["name"]) if artifact.key?("name")
      string!(artifact["description"]) if artifact.key?("description")
      artifact
    end

    def self.parts!(parts)
      raise Invalid unless parts.is_a?(Array) && parts.any?
      parts.each do |part|
        object!(part)
        # Preserve file outputs without fetching URLs (§5.6).
        keys = %w[text data raw url].select { |key| part.key?(key) }
        raise Invalid unless keys.size == 1
        key = keys.first
        raise Invalid unless key == "data" || part[key].is_a?(String)
        string!(part["mediaType"]) if part.key?("mediaType")
        raise Invalid if part.key?("filename") && !part["filename"].is_a?(String)
        if key == "raw"
          # ProtoJSON bytes permit standard/URL-safe alphabets and omitted
          # padding (§5.6). Normalize padding, then decode strictly.
          encoded = part["raw"].tr("-_", "+/")
          raise Invalid unless encoded.match?(/\A[A-Za-z0-9+\/]*={0,2}\z/) && encoded.length % 4 != 1
          Base64.strict_decode64(encoded.ljust((encoded.length + 3) / 4 * 4, "="))
        end
        metadata!(part)
      end
    end

    def self.safe_error_details!(details)
      raise Invalid unless details.is_a?(Array)
      details.each do |detail|
        object!(detail)
        raise Invalid unless (detail.keys - %w[@type reason domain metadata]).empty?
        raise Invalid unless detail["@type"] == "type.googleapis.com/google.rpc.ErrorInfo" &&
          detail["domain"] == "a2a-protocol.org" && Error::REASONS.value?(detail["reason"])
        raise Invalid if detail.key?("metadata") && detail["metadata"] != {}
      end
    end

    def self.metadata!(object)
      object!(object["metadata"]) if object.key?("metadata")
    end

    def self.strings!(object, key)
      list!(object, key) { |value| string!(value) }
    end

    def self.list!(object, key)
      return unless object.key?(key)
      raise Invalid unless object[key].is_a?(Array)
      object[key].each { |value| yield value }
    end

    def self.string!(value)
      raise Invalid unless value.is_a?(String) && value.present?
    end

    def self.object!(value)
      raise Invalid unless value.is_a?(Hash)
    end

    def initialize(task: nil, message: nil, error: nil)
      @task, @message, @error = task, message, error
    end
  end
end
