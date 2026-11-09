require "delegate"
require "ipaddr"
require "json"
require "net/http"
require "resolv"
require "timeout"
require "zlib"

module A2a
  # A2A §7: credentials and caller attribution are transport concerns. This
  # provider neither interprets JSON-RPC nor decides a delivery's execution route.
  class NativeTransport
    REQUEST_LIMIT = 1.megabyte
    CARD_LIMIT = 256.kilobytes
    SNAPSHOT_LIMIT = 2.megabytes
    CONNECT_TIMEOUT = 5
    PHASE_TIMEOUT = 2
    IO_TIMEOUT = 5
    TOTAL_TIMEOUT = 10
    SLOT_LIMITS = { dispatch: [ 8, 2 ], follow: [ 4, 1 ] }.freeze
    ATTRIBUTION_HEADERS = %w[Concourse-Caller Concourse-Task Concourse-Delivery Concourse-Via A2A-Extensions].freeze
    Response = Data.define(:status, :body, :headers)

    class Error < StandardError
      attr_reader :reason, :phase

      def initialize(reason, phase: :policy)
        @reason, @phase = reason, phase
        super("native transport #{reason}")
      end

      def certainly_unsent?
        false
      end

      def evidence
        reason if certainly_unsent?
      end
    end

    class AdmissionFailure < StandardError
      attr_reader :original

      def initialize(original)
        @original = original
        super("native admission interrupted")
      end
    end

    class ConfigurationError < Error; end
    class CapacityExceeded < Error; end
    class Unconfirmed < Error; end
    class Unavailable < Error
      def certainly_unsent?
        true
      end
    end

    # Reject whole answer sets, not just the address selected for this socket.
    # Transition/translation ranges cannot smuggle a private IPv4 destination.
    NON_PUBLIC_V4 = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24
      192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
      224.0.0.0/4 240.0.0.0/4 168.63.129.16/32
    ].map { |range| IPAddr.new(range) }.freeze
    GLOBAL_V6 = IPAddr.new("2000::/3")
    NON_PUBLIC_V6 = %w[2001::/23 2001:db8::/32 2002::/16 3ffe::/16 3fff::/20].map { |range| IPAddr.new(range) }.freeze

    def self.relay_complete?
      Agent.respond_to?(:native_relay_complete?) && Agent.native_relay_complete? == true
    end

    def self.production_outbound_guard
      raise ConfigurationError.new(:relay_incomplete) unless relay_complete?
      raise ConfigurationError.new(:outbound_disabled) unless Rails.app.creds.option(:relay, :outbound_enabled).to_s == "true"
    end

    def self.https_uri(value)
      raise ConfigurationError.new(:url_policy) unless value.is_a?(String) && value.bytesize <= 2048

      uri = URI.parse(value)
      host = uri.host.to_s
      labels = host.split(".", -1)
      valid_host = labels.length >= 2 && labels.all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) } && labels.last.match?(/\A[a-z]+\z/)
      valid_path = uri.path.to_s.match?(/\A\/[a-zA-Z0-9._~\/-]*\z/)
      unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && valid_host && valid_path
        raise ConfigurationError.new(:url_policy)
      end
      uri
    rescue URI::InvalidURIError
      raise ConfigurationError.new(:url_policy), cause: nil
    end

    def self.public_address(value)
      unless value.is_a?(String) && !value.match?(/[\/%]/)
        raise ConfigurationError.new(:dns_policy, phase: :dns)
      end
      address = IPAddr.new(value)
      address = address.native if address.ipv4_mapped?
      permitted = if address.ipv4?
        NON_PUBLIC_V4.none? { |range| range.include?(address) }
      else
        GLOBAL_V6.include?(address) && NON_PUBLIC_V6.none? { |range| range.include?(address) }
      end
      raise ConfigurationError.new(:dns_policy, phase: :dns) unless permitted

      address.to_s
    rescue IPAddr::Error, ArgumentError
      raise ConfigurationError.new(:dns_policy, phase: :dns), cause: nil
    end

    @slot_mutex = Mutex.new
    @active = Hash.new(0)
    @organizations = Hash.new(0)

    # These are additional process-local guards, not cross-process leases.
    # Callers must acquire the owning RelayNetworkSlot database lease as well.
    def self.with_slot(organization_id, purpose: :dispatch)
      acquired = false
      global_limit, organization_limit = SLOT_LIMITS.fetch(purpose)
      key = [ purpose, organization_id ]
      @slot_mutex.synchronize do
        if @active[purpose] >= global_limit || @organizations[key] >= organization_limit
          raise CapacityExceeded.new(:capacity)
        end
        @active[purpose] += 1
        @organizations[key] += 1
        acquired = true
      end
      yield
    ensure
      if acquired
        @slot_mutex.synchronize do
          @active[purpose] -= 1
          @organizations[key] -= 1
          @organizations.delete(key) if @organizations[key].zero?
        end
      end
    end

    # Bound decrypted wire bytes before Net::HTTP can accumulate status/header
    # lines. Body-only limits would still permit an unbounded header response.
    class BoundedIO < SimpleDelegator
      def initialize(io, limit)
        super(io)
        @limit, @received = limit, 0
      end

      def read_nonblock(*arguments, **options)
        chunk = __getobj__.read_nonblock(*arguments, **options)
        if chunk.is_a?(String)
          @received += chunk.bytesize
          raise Unconfirmed.new(:reply_limit, phase: :http) if @received > @limit
        end
        chunk
      end
    end

    # max_retries=0 alone does not prohibit Net::HTTP's pre-write reconnect.
    # A second connection would need a new DNS/policy check; never open one here.
    class PinnedHTTP < Net::HTTP
      attr_reader :connection_phase
      attr_accessor :reply_byte_limit, :stream_control

      private

      def connect
        raise Unconfirmed.new(:reconnect, phase: :http) if @connection_attempted

        @connection_attempted = true
        super
        io = if stream_control
          Streaming::SocketIO.new(@socket.io, stream_control)
        else
          BoundedIO.new(@socket.io, reply_byte_limit || SNAPSHOT_LIMIT)
        end
        @socket = Net::BufferedIO.new(io, read_timeout: read_timeout, write_timeout: write_timeout)
      end

      def timeouted_connect(*arguments)
        @connection_phase = :tcp
        super
      end

      def ssl_socket_connect(*arguments)
        @connection_phase = :tls
        super
      end
    end

    # Shared bounded HTTPS primitive; Ajent uses it only for its configured
    # token URL. Opening a direct TLS session sends no HTTP CONNECT or 0-RTT.
    class Connection
      class ConnectDeadline < Timeout::Error; end
      class TotalDeadline < Timeout::Error; end
      NETWORK_ERRORS = [ Net::OpenTimeout, EOFError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
        Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE ].freeze

      def initialize(resolver: nil, http_factory: nil)
        @resolver = resolver || ->(host) { Addrinfo.getaddrinfo(host, 443, Socket::AF_UNSPEC, Socket::SOCK_STREAM).map(&:ip_address).uniq }
        @http_factory = http_factory || ->(host) { PinnedHTTP.new(host, 443, nil) }
      end

      def perform(uri:, request:, response_limit:, guard: nil, admission: nil)
        phase = :policy
        http = nil
        guard ||= NativeTransport.method(:production_outbound_guard)
        guard.call
        Timeout.timeout(TOTAL_TIMEOUT, TotalDeadline) do
          Timeout.timeout(CONNECT_TIMEOUT, ConnectDeadline) do
            phase = :dns
            answers = Timeout.timeout(PHASE_TIMEOUT, ConnectDeadline) { @resolver.call(uri.host) }
            raise Unavailable.new(:dns_unavailable, phase: :dns) if answers.is_a?(Array) && answers.empty?
            raise ConfigurationError.new(:dns_policy, phase: :dns) unless answers.is_a?(Array)

            phase = :policy
            addresses = answers.map { |address| NativeTransport.public_address(address) }
            http = @http_factory.call(uri.host)
            configure(http, addresses.first, response_limit)
            guard.call
            invoke_admission!(admission)
            phase = :connecting
            http.start
          end
          guard.call
          invoke_admission!(admission)
          # A2A §3.3.1 makes send idempotency optional. Once request is entered,
          # even a partial write/reset is uncertain, never a fallback proof.
          phase = :http
          http.request(request) do |response|
            response.ignore_eof = false
            body = bounded_body(response, response_limit, guard)
            return Response.new(status: response.code.to_i, body: body, headers: response_headers(response))
          end
          raise Unconfirmed.new(:missing_response, phase: :http)
        ensure
          http.finish if http&.started?
        end
      rescue AdmissionFailure => error
        raise error.original, cause: nil
      rescue Error => error
        if phase == :http && error.is_a?(ConfigurationError)
          raise Unconfirmed.new(error.reason, phase: :http), cause: nil
        end
        raise
      rescue SocketError
        failure = phase == :dns ? Unavailable : Unconfirmed
        raise failure.new(:dns_unavailable, phase: phase), cause: nil
      rescue ConnectDeadline, *NETWORK_ERRORS => error
        phase = http.connection_phase if phase == :connecting && http.respond_to?(:connection_phase) && http.connection_phase
        failure = %i[dns tcp tls connecting].include?(phase) ? Unavailable : Unconfirmed
        reason = if failure == Unconfirmed
          :invalid_or_incomplete_response
        elsif phase == :dns
          :dns_unavailable
        elsif error.is_a?(ConnectDeadline) || error.is_a?(Net::OpenTimeout) || error.is_a?(Errno::ETIMEDOUT)
          :connect_timeout
        elsif phase == :tls
          :tls_network_failure
        elsif error.is_a?(Errno::ECONNREFUSED)
          :tcp_refused
        else
          :tcp_unreachable
        end
        raise failure.new(reason, phase: phase), cause: nil
      rescue OpenSSL::SSL::SSLError
        # SSLError also covers TLS alerts/EOFs without positive network evidence.
        # Do not infer availability from an exception message or bypass bad TLS.
        failure = phase == :http ? Unconfirmed : ConfigurationError
        raise failure.new(:tls_policy, phase: phase), cause: nil
      rescue TotalDeadline, Timeout::Error, IOError, SystemCallError, Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error
        raise Unconfirmed.new(:invalid_or_incomplete_response, phase: phase), cause: nil
      end

      private

      def invoke_admission!(callback)
        return unless callback
        begin
          value = callback.call
        rescue StandardError => error
          raise AdmissionFailure.new(error), cause: nil
        end
        raise ConfigurationError.new(:admission) if value == false
      end

      def configure(http, address, response_limit)
        http.ipaddr = address
        http.reply_byte_limit = response_limit if http.respond_to?(:reply_byte_limit=)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname = true
        http.min_version = OpenSSL::SSL::TLS1_2_VERSION
        http.open_timeout = PHASE_TIMEOUT
        http.read_timeout = IO_TIMEOUT
        http.write_timeout = IO_TIMEOUT
        http.max_retries = 0
        http.keep_alive_timeout = 0
      end

      def bounded_body(response, limit, guard)
        response.decode_content = false
        encoding = response["content-encoding"].to_s.downcase
        unless [ "", "identity", "gzip", "deflate" ].include?(encoding)
          raise Unconfirmed.new(:content_encoding, phase: :http)
        end
        if response["content-length"] && (!response["content-length"].match?(/\A\d+\z/) || response["content-length"].to_i > limit)
          raise Unconfirmed.new(:reply_limit, phase: :http)
        end
        inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 32) if %w[gzip deflate].include?(encoding)
        body = +"".b
        wire_bytes = 0
        append = ->(chunk) do
          guard.call
          raise Unconfirmed.new(:reply_limit, phase: :http) if body.bytesize + chunk.bytesize > limit
          body << chunk
        end
        response.read_body do |chunk|
          guard.call
          wire_bytes += chunk.bytesize
          raise Unconfirmed.new(:reply_limit, phase: :http) if wire_bytes > limit
          inflater ? inflater.inflate(chunk, &append) : append.call(chunk)
        end
        if inflater
          inflater.finish(&append)
          unless inflater.finished? && inflater.total_in == wire_bytes
            raise Unconfirmed.new(:content_encoding, phase: :http)
          end
        end
        body
      ensure
        inflater&.close
      end

      def response_headers(response)
        %w[content-type retry-after].each_with_object({}) do |key, headers|
          value = response[key]
          headers[key] = value if value && value.bytesize <= 1024
        end
      end
    end

    def initialize(organization_id:, recipient_id:, attribution: nil, purpose: :dispatch, settings: nil, connection: nil)
      @organization_id, @recipient_id = organization_id.to_s, recipient_id.to_s
      header_value(@organization_id)
      header_value(@recipient_id)
      @explicit_attribution = !attribution.nil?
      @attribution = attribution || { organization: @organization_id, recipient: @recipient_id }
      raise ConfigurationError.new(:attribution) unless @attribution.is_a?(Hash) && @attribution.keys.sort == %i[organization recipient]
      @attribution.each_value { |value| header_value(value) }
      raise ConfigurationError.new(:purpose) unless SLOT_LIMITS.key?(purpose)
      @purpose = purpose
      @injected_settings = !settings.nil?
      @settings = settings || ->(key) { Rails.app.creds.option(:relay, key) }
      @connection = connection || Connection.new
    end

    def post(url:, resource:, body:, token:, headers: {}, response_limit: SNAPSHOT_LIMIT, admission: nil)
      uri = permitted_uri(url, resource, :endpoint_url)
      unless response_limit.is_a?(Integer) && response_limit.between?(1, SNAPSHOT_LIMIT)
        raise ConfigurationError.new(:request_limit)
      end
      request = native_request(uri, body, token, headers)
      # Also honor admission with a constructor-injected connection/mock.
      raise ConfigurationError.new(:admission) if admission&.call == false
      dispatch(uri, request, response_limit, admission: admission)
    end

    def get_card(url:, resource:)
      uri = permitted_uri(url, resource, :card_url)
      dispatch(uri, Net::HTTP::Get.new(uri.request_uri), CARD_LIMIT)
    end

    private

    def permitted_uri(url, resource, kind)
      outbound_guard
      uri = self.class.https_uri(url)
      self.class.https_uri(resource)
      entries = @settings.call(:allowed_endpoints)
      if entries.is_a?(String)
        raise ConfigurationError.new(:allowlist) if entries.bytesize > 64.kilobytes
        entries = JSON.parse(entries)
      end
      permitted = entries.is_a?(Array) && entries.any? do |entry|
        next false unless entry.is_a?(Hash)
        values = entry.stringify_keys
        values["organization_id"].to_s == @organization_id && values["recipient_id"].to_s == @recipient_id && values["resource"] == resource && values[kind.to_s] == url
      end
      raise ConfigurationError.new(:allowlist) unless permitted
      uri
    rescue JSON::ParserError
      raise ConfigurationError.new(:allowlist), cause: nil
    end

    def dispatch(uri, request, limit, admission: nil)
      request["Accept"] = "application/json"
      request["Accept-Encoding"] = "gzip, deflate"
      request["Connection"] = "close"
      self.class.with_slot(@organization_id, purpose: @purpose) do
        arguments = { uri: uri, request: request, response_limit: limit, guard: method(:outbound_guard) }
        arguments[:admission] = admission if admission
        @connection.perform(**arguments)
      end
    end

    def outbound_guard
      raise ConfigurationError.new(:relay_incomplete) unless @injected_settings || self.class.relay_complete?
      raise ConfigurationError.new(:outbound_disabled) unless @settings.call(:outbound_enabled).to_s == "true"
    end

    def header_value(value)
      unless value.is_a?(String) && value.bytesize.between?(1, 512) && value.match?(/\A[\x20-\x7e]+\z/)
        raise ConfigurationError.new(:headers)
      end
      value
    end

    include Streaming
    Connection.include Streaming::ConnectionMethods
  end
end
