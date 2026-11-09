module A2a
  # JSON-RPC codes from A2A v1.0 §5.4 and §9.5. Messages are the spec's
  # standard strings where it names one, and otherwise say nothing a caller
  # could use to tell "missing" from "not yours" (§13.1).
  class Error < StandardError
    CODES = {
      parse: -32700,
      invalid_request: -32600,
      method_not_found: -32601,
      invalid_params: -32602,
      internal: -32603,
      task_not_found: -32001,
      task_not_cancelable: -32002,
      push_notification_not_supported: -32003,
      unsupported_operation: -32004,
      content_type_not_supported: -32005,
      extended_agent_card_not_configured: -32007,
      version_not_supported: -32009
    }.freeze

    MESSAGES = {
      parse: "Invalid JSON payload",
      invalid_request: "Request payload validation error",
      method_not_found: "Method not found",
      invalid_params: "Invalid parameters",
      internal: "Internal error",
      task_not_found: "Task not found",
      task_not_cancelable: "Task not cancelable",
      push_notification_not_supported: "Push notifications are not supported",
      unsupported_operation: "Unsupported operation",
      content_type_not_supported: "Content type not supported",
      extended_agent_card_not_configured: "Extended agent card is not configured",
      version_not_supported: "A2A version not supported"
    }.freeze

    REASONS = {
      task_not_found: "TASK_NOT_FOUND",
      task_not_cancelable: "TASK_NOT_CANCELABLE",
      push_notification_not_supported: "PUSH_NOTIFICATION_NOT_SUPPORTED",
      unsupported_operation: "UNSUPPORTED_OPERATION",
      content_type_not_supported: "CONTENT_TYPE_NOT_SUPPORTED",
      extended_agent_card_not_configured: "EXTENDED_AGENT_CARD_NOT_CONFIGURED",
      version_not_supported: "VERSION_NOT_SUPPORTED"
    }.freeze

    attr_reader :code, :data

    # A caller already allowed to see the task may learn why it was refused.
    # The spec's ErrorInfo stays first; ours is added after it (JSON-RPC data
    # MAY carry further detail objects), under a fixed Concourse domain.
    CONCOURSE_DOMAIN = "concourse.krishnan.ca"
    TASK_TERMINAL = "TASK_TERMINAL"

    def self.task_terminal(next_step = nil)
      new(:unsupported_operation, detail: TASK_TERMINAL, message: [ "Task is already in a terminal state", next_step ].compact.join("; "))
    end

    def self.reply_required
      new(:unsupported_operation, detail: "REPLY_REQUIRED", message: "This task was received, not sent; use the recipient reply operation")
    end

    def initialize(name, detail: nil, message: nil)
      @name = name
      @code = CODES.fetch(name)
      @detail = detail
      @data = error_info
      super(message || MESSAGES.fetch(name))
    end

    def to_h
      body = { code: code, message: message }
      body[:data] = data if data
      body
    end

    private

    def error_info
      reason = REASONS[@name]
      return unless reason

      infos = [ { "@type" => "type.googleapis.com/google.rpc.ErrorInfo", "reason" => reason, "domain" => "a2a-protocol.org" } ]
      infos << { "@type" => "type.googleapis.com/google.rpc.ErrorInfo", "reason" => @detail, "domain" => CONCOURSE_DOMAIN } if @detail
      infos
    end
  end
end
