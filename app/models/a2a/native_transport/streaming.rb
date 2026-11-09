module A2a
  class NativeTransport
    module Streaming
      TURN_LIMIT = 45
      IDLE_LIMIT = 30
      TICK_INTERVAL = 2
      HEADER_LIMIT = 64.kilobytes
      TOTAL_LIMIT = 32.megabytes
      class StopTurn < StandardError; end

      # No background watchdog/DB connection. Net::BufferedIO waits on to_io;
      # wrapping that wait keeps normal 15s heartbeats alive while admission is
      # checked every 2s (net-protocol 0.4.0 rbuf_fill/write0).
      class Control
        attr_accessor :headers_complete

        def initialize(deadline:, guard:, admission:, on_tick:, clock:)
          @clock, @guard, @admission, @on_tick = clock, guard, admission, on_tick
          now = @clock.call
          @deadline = [ deadline, now + TURN_LIMIT ].min
          @last_byte, @last_tick, @received = now, now, 0
          @headers_complete = false
        end

        def bind_socket(io)
          @socket = io
        end

        def close_owned_socket!
          @socket&.close
        rescue IOError, SystemCallError
        end

        def check!
          now = @clock.call
          raise StopTurn if now >= @deadline
          raise Unconfirmed.new(:stream_idle, phase: :http) if now - @last_byte >= IDLE_LIMIT
          @guard.call
          invoke_callback!(@admission)
          if now - @last_tick >= TICK_INTERVAL
            @last_tick = now
            invoke_callback!(@on_tick)
          end
        end

        def invoke_callback!(callback)
          return unless callback
          begin
            value = callback.call
          rescue StandardError => error
            raise AdmissionFailure.new(error), cause: nil
          end
          raise Unconfirmed.new(:admission, phase: :http) if value == false
        end

        def received!(size)
          check!
          @last_byte = @clock.call
          @received += size
          limit = headers_complete ? TOTAL_LIMIT : HEADER_LIMIT
          raise Unconfirmed.new(:reply_limit, phase: :http) if @received > limit
        end
      end

      class SocketIO < SimpleDelegator
        def initialize(io, control)
          super(io)
          @control = control
          control.bind_socket(self)
        end

        def to_io
          self
        end

        def read_nonblock(*args, **options)
          @control.check!
          chunk = __getobj__.read_nonblock(*args, **options)
          @control.received!(chunk.bytesize) if chunk.is_a?(String)
          chunk
        rescue StandardError
          __getobj__.close
          raise
        end

        def wait_readable(timeout)
          wait_for(:wait_readable, timeout)
        end

        def wait_writable(timeout)
          wait_for(:wait_writable, timeout)
        end

        private

        def wait_for(method, timeout)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            @control.check!
            left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return nil if left <= 0
            return self if __getobj__.to_io.public_send(method, [ TICK_INTERVAL, left ].min)
          end
        rescue StandardError
          __getobj__.close
          raise
        end
      end

      # SSE framing (§9.4): blank-line dispatch, comments, multi-data and
      # arbitrary socket splits. No reconnect IDs or retry directives followed.
      class Parser
        def initialize(&block)
          @emit = block
          @buffer, @data, @frame_size, @total = +"".b, [], 0, 0
          @skip_lf = false
          @first_line = true
        end

        def feed(chunk)
          @total += chunk.bytesize
          raise Unconfirmed.new(:reply_limit, phase: :http) if @total > TOTAL_LIMIT
          @buffer << chunk.b
          loop do
            @buffer = @buffer.byteslice(1..) if @skip_lf && @buffer.start_with?("\n")
            @skip_lf = false unless @buffer.empty?
            index = @buffer.index(/[\r\n]/)
            break unless index
            line = @buffer.byteslice(0, index)
            @skip_lf = @buffer.getbyte(index) == 13
            @buffer = @buffer.byteslice(index + 1..)
            process_line(line)
          end
          raise Unconfirmed.new(:event_limit, phase: :http) if @buffer.bytesize + @frame_size > SNAPSHOT_LIMIT
        end

        def finish!
          # EOF does not dispatch an unterminated event; do not silently accept
          # a truncated native observation as a successful turn.
          raise Unconfirmed.new(:incomplete_event, phase: :http) unless @buffer.empty? && @data.empty?
        end

        private

        def process_line(bytes)
          line = bytes.force_encoding(Encoding::UTF_8)
          raise Unconfirmed.new(:stream_utf8, phase: :http) unless line.valid_encoding?
          @frame_size += bytes.bytesize + 1
          raise Unconfirmed.new(:event_limit, phase: :http) if @frame_size > SNAPSHOT_LIMIT
          # WHATWG SSE ignores one leading BOM; frame limits still count it (§9.4).
          if @first_line
            line = line.delete_prefix("\uFEFF")
            @first_line = false
          end
          if line.empty?
            emit unless @data.empty?
            @data, @frame_size = [], 0
          elsif !line.start_with?(":")
            field, value = line.split(":", 2)
            value = value.to_s.delete_prefix(" ")
            @data << value if field == "data"
          end
        end

        def emit
          envelope = JSON.parse(@data.join("\n"), max_nesting: 100)
          unless envelope.is_a?(Hash) && envelope["jsonrpc"] == "2.0" && envelope.key?("id") &&
              (envelope.key?("result") ^ envelope.key?("error"))
            raise Unconfirmed.new(:stream_envelope, phase: :http)
          end
          if envelope.key?("error")
            error = envelope["error"]
            unless error.is_a?(Hash) && error["code"].is_a?(Integer) && error["message"].is_a?(String)
              raise Unconfirmed.new(:stream_envelope, phase: :http)
            end
          elsif !envelope["result"].is_a?(Hash)
            raise Unconfirmed.new(:stream_envelope, phase: :http)
          end
          @emit.call(envelope)
        rescue JSON::ParserError, ArgumentError
          raise Unconfirmed.new(:stream_json, phase: :http), cause: nil
        end
      end

      module ConnectionMethods
        def subscribe(uri:, request:, guard:, admission:, on_tick:, deadline:, &block)
          http = nil
          control = Control.new(deadline: deadline, guard: guard, admission: admission, on_tick: on_tick,
            clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          control.check!
          Timeout.timeout(CONNECT_TIMEOUT, Connection::ConnectDeadline) do
            answers = Timeout.timeout(PHASE_TIMEOUT, Connection::ConnectDeadline) { @resolver.call(uri.host) }
            raise Unavailable.new(:dns_unavailable, phase: :dns) if answers.is_a?(Array) && answers.empty?
            raise ConfigurationError.new(:dns_policy, phase: :dns) unless answers.is_a?(Array)
            addresses = answers.map { |answer| NativeTransport.public_address(answer) }
            http = @http_factory.call(uri.host)
            configure(http, addresses.first, TOTAL_LIMIT)
            raise ConfigurationError.new(:stream_socket) unless http.respond_to?(:stream_control=)
            http.stream_control = control
            # Thirty-second idle, not two-second read timeout. SocketIO ticks
            # while waiting; TCP/TLS retain their two-second phase bounds.
            http.read_timeout = IDLE_LIMIT
            control.check!
            http.start
          end
          control.check!
          http.request(request) do |response|
            response.ignore_eof = false
            response.decode_content = false
            control.headers_complete = true
            headers = response_headers(response)
            return Response.new(status: response.code.to_i, body: "", headers: headers) unless response.code == "200"
            unless response["content-type"].to_s.split(";", 2).first.to_s.strip.downcase == "text/event-stream" &&
                [ "", "identity" ].include?(response["content-encoding"].to_s.downcase)
              raise Unconfirmed.new(:stream_content_type, phase: :http)
            end
            parser = Parser.new do |envelope|
              control.check!
              raise StopTurn if block.call(envelope) == false
            end
            failure = nil
            begin
              response.read_body do |chunk|
                begin
                  control.received!(0)
                  parser.feed(chunk)
                rescue StandardError => error
                  # net-http read_chunked ensures a CRLF read after the block.
                  # Close our socket BEFORE that cleanup and retain the cause.
                  failure = error
                  control.close_owned_socket!
                  raise
                end
              end
              parser.finish!
            ensure
              raise failure, cause: nil if failure
            end
            return Response.new(status: 200, body: "", headers: headers)
          end
          raise Unconfirmed.new(:missing_response, phase: :http)
        rescue StopTurn
          Response.new(status: 200, body: "", headers: {})
        rescue AdmissionFailure => error
          raise error.original, cause: nil
        rescue Error
          raise
        rescue SocketError, Timeout::Error, IOError, SystemCallError, EOFError, Net::HTTPBadResponse, Net::ProtocolError, OpenSSL::SSL::SSLError
          raise Unconfirmed.new(:stream_transport, phase: :http), cause: nil
        ensure
          http.finish if http&.started?
        end
      end

      def subscribe(url:, resource:, body:, token:, headers: {}, admission:, on_tick:, deadline:, &block)
        raise ConfigurationError.new(:purpose) unless @purpose == :follow
        raise ConfigurationError.new(:stream_deadline) unless deadline.is_a?(Numeric) && deadline.finite?
        uri = permitted_uri(url, resource, :endpoint_url)
        request = native_request(uri, body, token, headers)
        request["Accept"] = "text/event-stream"
        request["Accept-Encoding"] = "identity"
        request["Connection"] = "close"
        self.class.with_slot(@organization_id, purpose: :follow) do
          @connection.subscribe(uri: uri, request: request, guard: method(:outbound_guard),
            admission: admission, on_tick: on_tick, deadline: deadline, &block)
        end
      end

      private

      def native_request(uri, body, token, headers)
        raise ConfigurationError.new(:attribution) unless @injected_settings || @explicit_attribution
        raise ConfigurationError.new(:request_limit) unless body.is_a?(String) && body.bytesize <= REQUEST_LIMIT
        unless token.is_a?(String) && token.match?(/\A[a-zA-Z0-9._~+\/-]+=*\z/) && token.bytesize <= 4096
          raise ConfigurationError.new(:token)
        end
        request = Net::HTTP::Post.new(uri.request_uri)
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"
        request["A2A-Version"] = "1.0"
        request["Concourse-Organization"] = header_value(@attribution.fetch(:organization))
        request["Concourse-Recipient"] = header_value(@attribution.fetch(:recipient))
        headers.each do |key, value|
          raise ConfigurationError.new(:headers) unless ATTRIBUTION_HEADERS.include?(key)
          raise ConfigurationError.new(:headers) if key == "Concourse-Via" && value != "owner"
          request[key] = header_value(value)
        end
        request.body = body
        request
      end
    end
  end
end
