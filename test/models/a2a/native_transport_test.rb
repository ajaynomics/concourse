require "test_helper"

class A2a::NativeTransportTest < ActiveSupport::TestCase
  Transport = A2a::NativeTransport
  ENDPOINT = "https://native.example.test/a2a"
  CARD = "https://native.example.test/.well-known/agent-card.json"
  PUBLIC_IP = "8.8.8.8"

  class Reply
    attr_accessor :ignore_eof, :decode_content
    attr_reader :code

    def initialize(code: "200", chunks: [ "{}" ], headers: {})
      @code, @chunks, @headers = code, chunks, headers
    end

    def [](key)
      @headers[key]
    end

    def read_body
      @chunks.each { |chunk| yield chunk }
    end
  end

  class HTTP < Net::HTTP
    attr_accessor :start_error, :request_error, :reply, :before_start, :before_request, :connection_phase
    attr_reader :requests, :finishes

    def initialize(host, port = 443)
      super(host, port)
      @requests, @finishes = [], 0
      @reply = Reply.new
      @connection_phase = :tcp
    end

    def start
      @before_start&.call
      raise @start_error if @start_error
      @started = true
      self
    end

    def request(request)
      @requests << request
      @before_request&.call
      raise @request_error if @request_error
      yield @reply
    end

    def finish
      @finishes += 1
      @started = false
    end
  end

  setup do
    @settings = {
      outbound_enabled: true,
      allowed_endpoints: [ { organization_id: "org", recipient_id: "recipient", endpoint_url: ENDPOINT, card_url: CARD, resource: ENDPOINT } ]
    }
    @lookups = []
    @answers = [ PUBLIC_IP, "2606:4700:4700::1111" ]
    @http = HTTP.new("native.example.test", 443, nil)
    @connection = Transport::Connection.new(
      resolver: ->(host) { @lookups << host; @answers },
      http_factory: ->(host) { assert_equal "native.example.test", host; @http }
    )
    @transport = transport
  end

  test "pins one public socket while retaining hostname certificate checks and disabling proxy and retries" do
    reply = post

    assert_equal 200, reply.status
    assert_equal "{}", reply.body
    assert_equal [ "native.example.test" ], @lookups
    assert_equal PUBLIC_IP, @http.ipaddr
    assert_equal "native.example.test", @http.address
    assert_not @http.proxy_from_env?
    assert_nil @http.proxy_address
    assert @http.use_ssl?
    assert_equal OpenSSL::SSL::VERIFY_PEER, @http.verify_mode
    assert @http.verify_hostname
    assert_equal OpenSSL::SSL::TLS1_2_VERSION, @http.min_version
    assert_equal 0, @http.max_retries
    assert_equal 0, @http.keep_alive_timeout
    assert_equal 2, @http.open_timeout
    assert_equal 5, @http.read_timeout
    assert_equal 5, @http.write_timeout
    assert_equal 1, @http.finishes
    assert_equal 1, @http.requests.length
  end

  test "requests fresh transport headers and preserves serialized protocol content without parsing it" do
    body = '{"jsonrpc":"2.0","id":"gateway","method":"SendMessage","params":{"message":{"messageId":"creator"}}}'
    # A2A §3.3.1: no message rewriting or automatic idempotent-send assumptions.
    post(body: body, headers: { "Concourse-Caller" => "caller", "Concourse-Task" => "public-task", "Concourse-Delivery" => "receipt", "A2A-Extensions" => "https://extension.example.test" })
    request = @http.requests.sole

    assert_equal body, request.body
    assert_equal "/a2a", request.path
    assert_equal "Bearer relay-token", request["Authorization"]
    assert_equal "1.0", request["A2A-Version"]
    assert_equal "org", request["Concourse-Organization"]
    assert_equal "recipient", request["Concourse-Recipient"]
    assert_equal "caller", request["Concourse-Caller"]
    assert_equal "public-task", request["Concourse-Task"]
    assert_equal "receipt", request["Concourse-Delivery"]
    assert_equal "close", request["Connection"]
    assert_nil request["Cookie"]
    assert_not @http.reply.ignore_eof
    assert_not @http.reply.decode_content
  end

  test "operator card verification sends no authorization or attribution and uses card cap" do
    @http.reply = Reply.new(chunks: [ "x" * (Transport::CARD_LIMIT + 1) ])
    assert_raises(Transport::Unconfirmed) { @transport.get_card(url: CARD, resource: ENDPOINT) }
    request = @http.requests.sole
    assert_nil request["Authorization"]
    assert_nil request["Concourse-Caller"]
    assert_nil request["Concourse-Organization"]
    assert_nil request["Concourse-Recipient"]
    assert_nil request["Concourse-Task"]
    assert_nil request["Concourse-Delivery"]
  end

  test "rejects URLs outside exact operator recipient organization path and resource binding before DNS" do
    [
      { url: "https://other.example.test/a2a" },
      { url: "https://native.example.test/not-approved" },
      { resource: "https://other.example.test/a2a" }
    ].each do |options|
      error = assert_raises(Transport::ConfigurationError) { post(**options) }
      assert_not error.certainly_unsent?
    end
    assert_raises(Transport::ConfigurationError) { post(provider: transport(organization_id: "other-org")) }
    assert_raises(Transport::ConfigurationError) { post(provider: transport(recipient_id: "other-recipient")) }
    assert_empty @lookups
  end

  test "HTTPS URL policy rejects IPs ambiguous hosts credentials ports queries fragments and escapes" do
    %w[
      http://native.example.test/a2a https://native.example.test:444/a2a
      https://name:secret@native.example.test/a2a https://native.example.test/a2a?x=1
      https://native.example.test/a2a#fragment https://127.0.0.1/a2a
      https://[::ffff:127.0.0.1]/a2a https://2130706433/a2a https://127.1/a2a
      https://native.example.test./a2a https://*.example.test/a2a
      https://native.example.test/a2a%0d%0a https://native.example.test
    ].each do |url|
      @settings[:allowed_endpoints].first[:endpoint_url] = url
      assert_raises(Transport::ConfigurationError) { post(url: url) }
    end
    assert_empty @lookups
  end

  test "all DNS answers must be public including IPv4 mapped and mixed answers" do
    %w[
      0.0.0.0 10.0.0.1 100.100.100.200 127.0.0.1 169.254.169.254
      172.16.0.1 192.0.0.1 192.0.2.1 192.168.1.1 198.18.0.1
      198.51.100.1 203.0.113.1 224.0.0.1 255.255.255.255 168.63.129.16
      :: ::1 fc00::1 fe80::1 ff02::1 2001:db8::1 2001::1 2002:7f00:1::1
      3fff::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1 ::ffff:169.254.169.254
      ::8.8.8.8 64:ff9b::7f00:1 not-an-address 8.8.8.8/24 2606:4700::1%eth0
    ].each do |answer|
      @answers = [ PUBLIC_IP, answer ]
      error = assert_raises(Transport::ConfigurationError) { post }
      assert_equal :dns_policy, error.reason
      assert_not error.certainly_unsent?
    end
    assert_empty @http.requests
    assert_equal PUBLIC_IP, Transport.public_address("::ffff:8.8.8.8")
    assert_equal "2606:4700:4700::1111", Transport.public_address("2606:4700:4700::1111")
  end

  test "each new connection resolves again and rejects rebinding before connecting" do
    post
    @answers = [ "127.0.0.1" ]
    assert_raises(Transport::ConfigurationError) { post }
    assert_equal 2, @lookups.length
    assert_equal 1, @http.requests.length
  end

  test "positive DNS unavailability and pre HTTP connection failures expose certain unsent evidence" do
    [ [], -> { raise SocketError, "private DNS diagnostic" }, -> { raise Transport::Connection::ConnectDeadline } ].each do |answer|
      @answers = answer
      resolver = ->(_host) { answer.respond_to?(:call) ? answer.call : answer }
      connection = Transport::Connection.new(resolver: resolver, http_factory: ->(_host) { flunk "must not connect" })
      error = assert_raises(Transport::Unavailable) { post(provider: transport(connection: connection)) }
      assert error.certainly_unsent?
      assert_equal :dns, error.phase
      assert_nil error.cause
    end
    @answers = [ PUBLIC_IP ]
    [ [ Errno::ECONNREFUSED.new, :tcp_refused ], [ Errno::ENETUNREACH.new, :tcp_unreachable ],
      [ Net::OpenTimeout.new, :connect_timeout ], [ EOFError.new, :tcp_unreachable ] ].each do |exception, reason|
      @http.start_error = exception
      error = assert_raises(Transport::Unavailable) { post }
      assert error.certainly_unsent?
      assert_equal :tcp, error.phase
      assert_equal reason, error.evidence
      assert_nil error.cause
    end
    assert_empty @http.requests
  end

  test "positively tracked TLS network failure permits certain unsent evidence but generic SSL errors do not" do
    @http.connection_phase = :tls
    @http.start_error = EOFError.new
    error = assert_raises(Transport::Unavailable) { post }
    assert_equal :tls, error.phase
    assert_equal :tls_network_failure, error.evidence
    assert error.certainly_unsent?
    @http.start_error = OpenSSL::SSL::SSLError.new("unexpected EOF")
    error = assert_raises(Transport::ConfigurationError) { post }
    assert_nil error.evidence
    assert_empty @http.requests
  end

  test "TLS certificate or policy failure is configuration not fallback even before HTTP" do
    @http.start_error = OpenSSL::SSL::SSLError.new("certificate verify failed with sensitive details")
    error = assert_raises(Transport::ConfigurationError) { post }
    assert_equal :tls_policy, error.reason
    assert_not error.certainly_unsent?
    assert_not_includes error.message, "sensitive"
    assert_nil error.cause
    assert_empty @http.requests
  end

  test "partial write reset read timeout and TLS EOF after request entry cannot permit fallback or retry" do
    [ Errno::ECONNREFUSED.new, Errno::ECONNRESET.new, Net::OpenTimeout.new, Net::ReadTimeout.new,
      Net::WriteTimeout.new, EOFError.new, IOError.new, OpenSSL::SSL::SSLError.new("secret") ].each do |exception|
      @http.request_error = exception
      error = assert_raises(Transport::Unconfirmed) { post }
      assert_not error.certainly_unsent?
      assert_equal :http, error.phase
      assert_nil error.cause
    end
    assert_equal 8, @http.requests.length
    assert_equal 8, @http.finishes
  end

  test "all status responses and invalid or mismatched JSON remain downstream decisions never fallback" do
    [ 301, 401, 403, 404, 408, 429, 500, 502, 503 ].each do |status|
      @http.reply = Reply.new(code: status.to_s, chunks: [ "not JSON" ], headers: {
        "location" => "https://evil.example.test/", "www-authenticate" => "private challenge", "set-cookie" => "secret", "retry-after" => "30"
      })
      reply = post
      assert_equal status, reply.status
      assert_equal "not JSON", reply.body
      assert_equal({ "retry-after" => "30" }, reply.headers)
    end
    @http.reply = Reply.new(chunks: [ '{"jsonrpc":"2.0","id":"wrong","result":{}}' ])
    assert_includes post.body, '"id":"wrong"'
    assert_equal 10, @http.requests.length
  end

  test "byte caps apply before sending and to wire and decompressed reply before parsing" do
    assert_raises(Transport::ConfigurationError) { post(body: "x" * (Transport::REQUEST_LIMIT + 1)) }
    assert_raises(Transport::ConfigurationError) { post(response_limit: Transport::SNAPSHOT_LIMIT + 1) }
    assert_empty @lookups
    @http.reply = Reply.new(chunks: [ "abc", "def" ])
    assert_raises(Transport::Unconfirmed) { post(response_limit: 5) }
    @http.reply = Reply.new(chunks: [ "unused" ], headers: { "content-length" => "6" })
    assert_raises(Transport::Unconfirmed) { post(response_limit: 5) }
    compressed = Zlib.gzip("x" * 4096)
    assert compressed.bytesize < 100
    @http.reply = Reply.new(chunks: [ compressed ], headers: { "content-encoding" => "gzip" })
    error = assert_raises(Transport::Unconfirmed) { post(response_limit: 100) }
    assert_equal :reply_limit, error.reason
    assert_not error.certainly_unsent?
  end

  test "bounded gzip responses decode and malformed or unsupported compression is unconfirmed" do
    @http.reply = Reply.new(chunks: [ Zlib.gzip("{\"hello\":1}") ], headers: { "content-encoding" => "gzip", "content-type" => "application/json" })
    assert_equal '{"hello":1}', post.body
    [ [ "gzip", "not gzip" ], [ "br", "compressed" ], [ "gzip", Zlib.gzip("{}") + "trailing" ] ].each do |encoding, content|
      @http.reply = Reply.new(chunks: [ content ], headers: { "content-encoding" => encoding })
      assert_raises(Transport::Unconfirmed) { post }
    end
  end

  test "outbound switch blocks before I O and rechecks between resolution connection and response chunks" do
    @settings[:outbound_enabled] = false
    assert_raises(Transport::ConfigurationError) { post }
    assert_empty @lookups
    @settings[:outbound_enabled] = true
    @http.before_start = -> { @settings[:outbound_enabled] = false }
    error = assert_raises(Transport::ConfigurationError) { post }
    assert_not error.certainly_unsent?
    assert_empty @http.requests
    @settings[:outbound_enabled] = true
    @http.before_start = nil
    @http.before_request = -> { @settings[:outbound_enabled] = false }
    error = assert_raises(Transport::Unconfirmed) { post }
    assert_not error.certainly_unsent?
    assert_equal 1, @http.requests.length
    assert_equal 2, @http.finishes
  end

  test "untrusted arbitrary or conflicting transport headers and control bytes fail before DNS" do
    [ { "Authorization" => "Bearer caller-token" }, { "Cookie" => "caller-cookie" },
      { "Concourse-Organization" => "spoof" }, { "Concourse-Recipient" => "spoof" },
      { "Concourse-Caller" => "caller\r\nAuthorization: hacked" }, { "A2A-Version" => "0.3" } ].each do |headers|
      assert_raises(Transport::ConfigurationError) { post(headers: headers) }
    end
    assert_raises(Transport::ConfigurationError) { post(token: "token\r\n") }
    assert_empty @lookups
  end

  test "phase and total deadlines are bounded independently" do
    deadlines = []
    timer = ->(seconds, *_arguments, &block) { deadlines << seconds; block.call }
    original_timer = Timeout.method(:timeout)
    begin
      Timeout.define_singleton_method(:timeout, timer)
      post
    ensure
      Timeout.define_singleton_method(:timeout, original_timer)
    end
    assert_equal [ 10, 5, 2 ], deadlines
    @http.request_error = Transport::Connection::TotalDeadline.new
    error = assert_raises(Transport::Unconfirmed) { post }
    assert_not error.certainly_unsent?
  end

  test "hidden pre write reconnection is refused even with zero normal retry allowance" do
    http = Transport::PinnedHTTP.new("native.example.test", 443, nil)
    http.instance_variable_set(:@connection_attempted, true)
    error = assert_raises(Transport::Unconfirmed) { http.send(:connect) }
    assert_equal :reconnect, error.reason
    assert_not error.certainly_unsent?
  end

  test "dispatch slots cap both organization and global use and release on every exit" do
    Transport.with_slot("org") do
      Transport.with_slot("org") do
        error = assert_raises(Transport::CapacityExceeded) { post }
        assert_not error.certainly_unsent?
        assert_empty @lookups
      end
    end
    occupy = ->(index) do
      if index == Transport::SLOT_LIMITS.fetch(:dispatch).first
        assert_raises(Transport::CapacityExceeded) { Transport.with_slot("another-org") { flunk } }
      else
        Transport.with_slot("org-#{index}") { occupy.call(index + 1) }
      end
    end
    occupy.call(0)
    assert_raises(RuntimeError) { Transport.with_slot("org") { raise "owned fault" } }
    assert_equal 200, post.status
  end

  test "follow pools are separate from dispatch and limited to four globally and one per organization" do
    follow = transport(purpose: :follow)
    Transport.with_slot("org", purpose: :follow) do
      assert_raises(Transport::CapacityExceeded) { post(provider: follow) }
      assert_equal 200, post.status
      Transport.with_slot("org") do
        Transport.with_slot("org") do
          assert_raises(Transport::CapacityExceeded) { post }
          assert_raises(Transport::CapacityExceeded) { post(provider: follow) }
        end
      end
    end
    assert_equal 200, post(provider: follow).status
    occupy = ->(index) do
      if index == Transport::SLOT_LIMITS.fetch(:follow).first
        assert_raises(Transport::CapacityExceeded) { Transport.with_slot("follow-other", purpose: :follow) { flunk } }
        assert_equal 200, post.status
      else
        Transport.with_slot("follow-#{index}", purpose: :follow) { occupy.call(index + 1) }
      end
    end
    occupy.call(0)
    assert_raises(Transport::ConfigurationError) { transport(purpose: :unknown) }
  end

  test "partial binary refuses default provider dispatch follow and card egress before reading configuration" do
    %i[dispatch follow].each do |purpose|
      provider = Transport.new(organization_id: "org", recipient_id: "recipient", purpose: purpose, connection: @connection)
      error = assert_raises(Transport::ConfigurationError) { post(provider: provider) }
      assert_equal :relay_incomplete, error.reason
      assert_nil error.evidence
      error = assert_raises(Transport::ConfigurationError) { provider.get_card(url: CARD, resource: ENDPOINT) }
      assert_equal :relay_incomplete, error.reason
    end
    assert_empty @lookups
    error = assert_raises(Transport::ConfigurationError) do
      @connection.perform(uri: URI(ENDPOINT), request: Net::HTTP::Post.new("/a2a"), response_limit: 100)
    end
    assert_equal :relay_incomplete, error.reason
  end

  test "operator JSON allowlist is accepted but malformed or oversized configuration fails before DNS" do
    @settings[:allowed_endpoints] = JSON.generate(@settings[:allowed_endpoints])
    assert_equal 200, post.status
    @lookups.clear
    [ "{bad JSON", "x" * (64.kilobytes + 1), "{}" ].each do |invalid|
      @settings[:allowed_endpoints] = invalid
      assert_raises(Transport::ConfigurationError) { post }
    end
    assert_empty @lookups
  end

  test "socket byte cap includes status headers framing and does not charge wait symbols" do
    chunks = [ :wait_readable, "HTTP/1.1 200 OK\r\n", "X-Large: #{"x" * 100}\r\n" ]
    io = Object.new
    io.define_singleton_method(:read_nonblock) { |*_arguments, **_options| chunks.shift }
    bounded = Transport::BoundedIO.new(io, 40)
    assert_equal :wait_readable, bounded.read_nonblock(16, exception: false)
    assert_equal "HTTP/1.1 200 OK\r\n", bounded.read_nonblock(16, exception: false)
    error = assert_raises(Transport::Unconfirmed) { bounded.read_nonblock(16, exception: false) }
    assert_equal :reply_limit, error.reason
    assert_nil error.evidence
    http = Transport::PinnedHTTP.new("native.example.test", 443, nil)
    assert http.respond_to?(:reply_byte_limit=)
  end

  private

  def transport(organization_id: "org", recipient_id: "recipient", purpose: :dispatch, connection: @connection)
    Transport.new(organization_id: organization_id, recipient_id: recipient_id, purpose: purpose, settings: ->(key) { @settings[key] }, connection: connection)
  end

  def post(provider: @transport, **options)
    provider.post(**{ url: ENDPOINT, resource: ENDPOINT, body: "{}", token: "relay-token" }.merge(options))
  end
end
