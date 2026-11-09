module A2a
  # JSON-RPC 2.0 dispatch for one agent endpoint (§9). Capability errors are
  # returned before any task lookup so a missing agent and a present one give
  # the same answer for push (§3.3.4, §13.1).
  class Rpc
    Result = Struct.new(:body, :notification, :stream, keyword_init: true)

    # The binding's stream (§9.4.2): a Rack streaming body that sends each
    # StreamResponse as one Server-Sent Event holding a JSON-RPC response
    # with the request's id, and a comment line while the task is quiet. An
    # error before the stream opens is an ordinary JSON-RPC response instead.
    EventStream = Data.define(:id, :stream) do
      # How a client that hangs up surfaces at the next write: Falcon raises
      # Protocol::HTTP errors, other servers the socket's own.
      CLIENT_LEFT = [ IOError, Errno::EPIPE, Errno::ECONNRESET, Protocol::HTTP::Error ].freeze

      def call(io)
        stream.each do |event|
          io.write(event ? "data: #{JSON.generate(jsonrpc: "2.0", id: id, result: event)}\n\n" : ": keepalive\n\n")
        end
      rescue *CLIENT_LEFT
        # The client left. The task goes on; another stream may follow it.
      rescue Error => exception
        begin
          io.write("data: #{JSON.generate(jsonrpc: "2.0", id: id, error: exception.to_h)}\n\n")
        rescue *CLIENT_LEFT
        end
      rescue StandardError => exception
        Rails.error.report(exception, handled: true, context: { source: "a2a.stream" })
        begin
          io.write("data: #{JSON.generate(jsonrpc: "2.0", id: id, error: Error.new(:internal).to_h)}\n\n")
        rescue *CLIENT_LEFT
        end
      ensure
        io.close
      end
    end

    STREAMING = %w[SendStreamingMessage SubscribeToTask].freeze
    PUSH = %w[
      CreateTaskPushNotificationConfig
      GetTaskPushNotificationConfig
      ListTaskPushNotificationConfigs
      DeleteTaskPushNotificationConfig
    ].freeze
    METHODS = %w[SendMessage SendStreamingMessage GetTask ListTasks CancelTask SubscribeToTask GetExtendedAgentCard].freeze

    def self.perform(...)
      new(...).perform
    end

    def initialize(caller_agent:, recipient:, body:, version:, content_type:)
      @caller = caller_agent
      @recipient = recipient
      @body = body.to_s
      @version = version
      @content_type = content_type
    end

    def perform
      id = nil
      unless Version.supported?(@version)
        return error(Error.new(:version_not_supported), id: peek_id)
      end
      # §9.1 requires application/json but does not name an error for a wrong
      # HTTP header. §9.5's -32600 is "the JSON sent is not a valid Request
      # object", which is the payload, not the header. §5.4 maps
      # ContentTypeNotSupportedError to -32005, and the TCK MUST test
      # JSONRPC-SSE-002 scores a wrong Content-Type header as -32005. -32600
      # would fail that test, so the header stays on the part-media-type code.
      unless @content_type == "application/json"
        return error(Error.new(:content_type_not_supported), id: peek_id)
      end

      request = parse_body
      return request if request.is_a?(Result)

      id = request["id"]
      method = request["method"]
      return Result.new(notification: true) if !request.key?("id") && method.is_a?(String)
      return error(Error.new(:invalid_request), id: id) unless method.is_a?(String)
      return error(Error.new(:push_notification_not_supported), id: id) if PUSH.include?(method)
      return error(Error.new(:method_not_found), id: id) unless METHODS.include?(method)
      return error(Error.new(:task_not_found), id: id) unless @recipient

      params = request.fetch("params", {})
      return error(Error.new(:invalid_params), id: id) unless params.is_a?(Hash)

      if STREAMING.include?(method)
        Result.new(stream: EventStream.new(id: id, stream: dispatch(method, params)))
      else
        Result.new(body: { jsonrpc: "2.0", id: id, result: dispatch(method, params) })
      end
    rescue Error => exception
      error(exception, id: id)
    rescue StandardError => exception
      raise if Rails.env.local?

      Rails.error.report(exception, handled: true, context: {
        source: "a2a.rpc",
        rpc_method: method.is_a?(String) ? method : nil,
        agent_id: @caller&.id,
        recipient_id: @recipient&.id
      }.compact)
      error(Error.new(:internal), id: id)
    end

    private

    def dispatch(method, params)
      case method
      when "SendMessage"
        send_message_result(params)
      when "SendStreamingMessage"
        Exchange.send_streaming_message(
          caller: @caller,
          recipient: @recipient,
          message: params["message"],
          configuration: params["configuration"] || {},
          metadata: params.fetch("metadata", {})
        )
      when "SubscribeToTask"
        Exchange.subscribe(viewer: @caller, id: params["id"], recipient: @recipient)
      when "GetTask"
        Exchange.get_task(
          viewer: @caller,
          id: params["id"],
          history_length: history_length(params),
          recipient: @recipient
        )
      when "ListTasks"
        Exchange.list_tasks(viewer: @caller, filters: params, recipient: @recipient)
      when "CancelTask"
        Exchange.cancel_task(caller: @caller, recipient: @recipient, id: params["id"], metadata: params.fetch("metadata", {}))
      when "GetExtendedAgentCard"
        Card.extended_for(@recipient)
      end
    end

    def send_message_result(params)
      sent = Exchange.send_message(
        caller: @caller,
        recipient: @recipient,
        message: params["message"],
        configuration: params["configuration"] || {},
        metadata: params.fetch("metadata", {})
      )
      if sent.is_a?(DirectMessage)
        { "message" => sent.to_h }
      else
        { "task" => sent }
      end
    end

    def history_length(params)
      return nil unless params.key?("historyLength") || params.key?("history_length")

      value = params.key?("historyLength") ? params["historyLength"] : params["history_length"]
      raise Error.new(:invalid_params) unless value.is_a?(Integer) && value >= 0

      value
    end

    def parse_body
      parsed = JSON.parse(@body)
      return error(Error.new(:invalid_request), id: nil) unless parsed.is_a?(Hash)
      return error(Error.new(:invalid_request), id: parsed["id"]) unless parsed["jsonrpc"] == "2.0"

      parsed
    rescue JSON::ParserError
      error(Error.new(:parse), id: nil)
    end

    def peek_id
      parsed = JSON.parse(@body)
      parsed.is_a?(Hash) ? parsed["id"] : nil
    rescue JSON::ParserError, TypeError
      nil
    end

    def error(exception, id:)
      Result.new(body: { jsonrpc: "2.0", id: id, error: exception.to_h })
    end
  end
end
