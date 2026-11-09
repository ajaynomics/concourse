require "test_helper"

class A2a::NativeStreamTransportTest < ActiveSupport::TestCase
  Transport = A2a::NativeTransport
  Streaming = Transport::Streaming
  ENDPOINT = "https://native.example.test/a2a"

  # A constructor-injected synthetic origin: only this test's fresh loopback
  # listener. Production DNS/HTTPS policy is never relaxed or configured.
  class LoopbackHTTP < Transport::PinnedHTTP
    def initialize(port, _default_port = nil)
      super("native.example.test", 443)
      @test_port = port
    end

    def start(&block)
      WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP.instance_method(:start).bind_call(self, &block)
    end

    def request(request, &block)
      WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP.instance_method(:request).bind_call(self, request, &block)
    end

    private

    def connect
      raise Transport::Unconfirmed.new(:reconnect) if @connection_attempted
      @connection_attempted = true
      io = TCPSocket.new("127.0.0.1", @test_port)
      @socket = Net::BufferedIO.new(Streaming::SocketIO.new(io, stream_control), read_timeout: read_timeout, write_timeout: write_timeout)
      @last_communicated = nil
    end
  end

  test "SSE blank lines comments multiline UTF8 and arbitrary CR LF splits emit raw envelopes" do
    result = []
    parser = Streaming::Parser.new { |envelope| result << envelope }
    wire = ": heartbeat\r\n\r\ndata: {\"jsonrpc\":\"2.0\",\r\ndata: \"id\":\"rpc\",\"result\":{\"message\":{\"text\":\"café\"}}}\r\n\r\n"
    wire.b.each_byte { |byte| parser.feed(byte.chr) }
    parser.finish!
    assert_equal 1, result.size
    assert_equal "rpc", result.sole["id"]
    assert_equal "café", result.sole.dig("result", "message", "text")
  end

  test "section 9.4 SSE ignores one leading UTF8 BOM across bytewise Task and delta frames" do
    task = { "jsonrpc" => "2.0", "id" => "rpc", "result" => { "task" => { "id" => "native", "contextId" => "context", "status" => { "state" => "TASK_STATE_WORKING" } } } }
    delta = { "jsonrpc" => "2.0", "id" => "rpc", "result" => { "statusUpdate" => { "taskId" => "native", "contextId" => "context", "status" => { "state" => "TASK_STATE_COMPLETED" } } } }
    [ "", "\uFEFF" ].each do |prefix|
      observed = []
      parser = Streaming::Parser.new { |envelope| observed << envelope }
      wire = "#{prefix}data: #{task.to_json}\r\n\r\ndata: #{delta.to_json}\r\n\r\n"
      wire.b.each_byte { |byte| parser.feed(byte.chr) }
      parser.finish!
      assert_equal [ task, delta ], observed
    end
  end

  test "SSE keeps later BOMs in data and treats BOM-prefixed fields as unknown" do
    envelope = { "jsonrpc" => "2.0", "id" => "rpc", "result" => { "message" => { "text" => "before\uFEFFafter" } } }
    observed = []
    parser = Streaming::Parser.new { |event| observed << event }
    wire = "\uFEFFdata: #{envelope.to_json}\n\n\uFEFFdata: #{envelope.to_json}\n\ndata: #{envelope.to_json}\n\n"
    wire.b.each_byte { |byte| parser.feed(byte.chr) }
    parser.finish!
    assert_equal [ envelope, envelope ], observed
    parser = Streaming::Parser.new { flunk "only one leading BOM may be ignored" }
    "\uFEFF\uFEFFdata: #{envelope.to_json}\n\n".b.each_byte { |byte| parser.feed(byte.chr) }
    parser.finish!
  end

  test "SSE truncated and malformed BOM prefixes fail without emitting or exposing content" do
    [ "\xef".b, "\xef\xbb".b ].each do |wire|
      parser = Streaming::Parser.new { flunk }
      wire.each_byte { |byte| parser.feed(byte.chr) }
      error = assert_raises(Transport::Unconfirmed) { parser.finish! }
      assert_equal :incomplete_event, error.reason
      assert_nil error.cause
    end
    [ "\xefprivate-body\n\n".b, "\xef\xbbprivate-body\n\n".b ].each do |wire|
      parser = Streaming::Parser.new { flunk }
      error = assert_raises(Transport::Unconfirmed) { wire.each_byte { |byte| parser.feed(byte.chr) } }
      assert_equal :stream_utf8, error.reason
      assert_not_includes error.message, "private-body"
      assert_nil error.cause
    end
  end

  test "SSE leading BOM does not relax original frame or total byte limits" do
    [ "", "\uFEFF" ].each do |prefix|
      parser = Streaming::Parser.new { flunk }
      frame = prefix.b + ":" + "x" * (Transport::SNAPSHOT_LIMIT - prefix.bytesize - 2) + "\n"
      parser.feed(frame)
      parser.finish!
      error = assert_raises(Transport::Unconfirmed) { parser.feed("\n") }
      assert_equal :event_limit, error.reason
      parser = Streaming::Parser.new { flunk }
      error = assert_raises(Transport::Unconfirmed) { parser.feed(prefix.b + ":" + "x" * (Transport::SNAPSHOT_LIMIT - prefix.bytesize - 1) + "\n") }
      assert_equal :event_limit, error.reason
      parser = Streaming::Parser.new { flunk }
      parser.feed(prefix)
      remaining = Streaming::TOTAL_LIMIT - prefix.bytesize
      chunk = ":" + "x" * (1.megabyte - 3) + "\n\n"
      while remaining >= chunk.bytesize
        parser.feed(chunk)
        remaining -= chunk.bytesize
      end
      parser.feed(":" + "x" * (remaining - 3) + "\n\n") if remaining > 0
      parser.finish!
      error = assert_raises(Transport::Unconfirmed) { parser.feed("\n") }
      assert_equal :reply_limit, error.reason
    end
  end

  test "invalid UTF8 JSON envelopes and unfinished data fail boundedly without provider content" do
    [ "data: \xff\n\n".b, "data: private-body\n\n", "data: []\n\n",
      'data: {"jsonrpc":"2.0","id":"rpc","result":{},"error":{}}' + "\n\n",
      'data: {"jsonrpc":"2.0","id":"rpc","error":{"code":"wrong","message":"secret"}}' + "\n\n" ].each do |wire|
      parser = Streaming::Parser.new { flunk }
      error = assert_raises(Transport::Unconfirmed) { parser.feed(wire) }
      assert_not_includes error.message, "private-body"
      assert_nil error.cause
    end
    parser = Streaming::Parser.new { flunk }
    parser.feed('data: {"jsonrpc":"2.0","id":"rpc","result":{}}')
    assert_raises(Transport::Unconfirmed) { parser.finish! }
    parser = Streaming::Parser.new { flunk }
    assert_raises(Transport::Unconfirmed) { parser.feed("x" * (Transport::SNAPSHOT_LIMIT + 1)) }
  end

  test "protocol error envelopes are raw downstream decisions and RPC ID is not rewritten" do
    result = []
    parser = Streaming::Parser.new { |value| result << value }
    parser.feed("data: #{JSON.generate(jsonrpc: '2.0', id: 'other-id', error: { code: -32001, message: 'refused' })}\n\n")
    assert_equal "other-id", result.sole["id"]
    assert_equal(-32001, result.sole.dig("error", "code"))
  end

  test "socket waits tick admission and close the actual owned socket on revocation without a send retry" do
    observed = []
    with_listener(->(socket) do
      read_request(socket)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
      # Peer intentionally waits; the client's own 2s tick must interrupt it.
      socket.read
    end) do |provider, http|
      ticks = 0
      error = assert_raises(Transport::Unconfirmed) do
        subscribe(provider, on_tick: -> { ticks += 1; false }) { |envelope| observed << envelope }
      end
      assert_equal :admission, error.reason
      assert_equal 1, ticks
      assert_empty observed
      assert_not http.started?
      assert http.instance_variable_get(:@socket).nil?
      assert_equal 0, http.max_retries
      assert_not http.proxy_from_env?
      assert http.verify_hostname
      assert_equal "8.8.8.8", http.ipaddr
    end
  end

  test "normal heartbeats remain connected beyond tick intervals and callback termination closes without draining" do
    received_request = nil
    with_listener(->(socket) do
      received_request = read_request(socket)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nTransfer-Encoding: chunked\r\n\r\n")
      write_chunk(socket, ": heartbeat\n\n")
      sleep 2.2 # Test-owned peer delay, not a production retry/job sleep.
      write_chunk(socket, "data: #{JSON.generate(jsonrpc: '2.0', id: 'rpc', result: { task: {} })}\n\n")
      socket.read
    end) do |provider, _http|
      ticks = 0
      events = []
      response = subscribe(provider, on_tick: -> { ticks += 1; true }) { |value| events << value; false }
      assert_equal 200, response.status
      assert_operator ticks, :>=, 1
      assert_equal 1, events.size
      assert_includes received_request, "Accept: text/event-stream"
      assert_includes received_request, "Accept-Encoding: identity"
      assert_includes received_request, "Authorization: Bearer synthetic-token"
      assert_not_includes received_request, "Cookie:"
    end
  end

  test "wrong content type compression redirects and auth failure never reconnect or expose arbitrary headers" do
    [ [ 200, "application/json", "" ], [ 200, "text/event-stream", "gzip" ], [ 302, "text/event-stream", "" ], [ 401, "text/event-stream", "" ] ].each do |status, type, encoding|
      with_listener(->(socket) do
        read_request(socket)
        socket.write("HTTP/1.1 #{status} Test\r\nContent-Type: #{type}\r\nContent-Encoding: #{encoding}\r\nLocation: https://evil.invalid\r\nSet-Cookie: secret\r\nWWW-Authenticate: secret\r\nContent-Length: 0\r\n\r\n")
      end) do |provider, _http|
        if status == 200
          assert_raises(Transport::Unconfirmed) { subscribe(provider) { flunk } }
        else
          response = subscribe(provider) { flunk }
          assert_equal status, response.status
          assert_nil response.headers["location"]
          assert_nil response.headers["www-authenticate"]
          assert_nil response.headers["set-cookie"]
        end
      end
    end
  end

  test "control caps headers total bytes idle and turn while ticks do not treat a 15s heartbeat as timeout" do
    now = 0.0
    ticks = 0
    control = Streaming::Control.new(deadline: 900.0, guard: -> { }, admission: -> { true }, on_tick: -> { ticks += 1 }, clock: -> { now })
    [ 2, 4, 6, 8, 10, 12, 14, 15 ].each { |time| now = time; control.check! }
    control.received!(10)
    assert_equal 7, ticks
    now = 44
    control.check!
    now = 45
    assert_raises(Streaming::StopTurn) { control.check! }
    now = 0
    control = Streaming::Control.new(deadline: 45, guard: -> { }, admission: -> { }, on_tick: -> { }, clock: -> { now })
    assert_raises(Transport::Unconfirmed) { control.received!(Streaming::HEADER_LIMIT + 1) }
    control.headers_complete = true
    assert_raises(Transport::Unconfirmed) { control.received!(Streaming::TOTAL_LIMIT + 1) }
  end

  test "post admission callback is checked after DNS and before request and never enables fallback" do
    starts = 0
    connection = Transport::Connection.new(resolver: ->(_host) { [ "8.8.8.8" ] }, http_factory: ->(_host) {
      http = Object.new
      %i[ipaddr= reply_byte_limit= use_ssl= verify_mode= verify_hostname= min_version= open_timeout= read_timeout= write_timeout= max_retries= keep_alive_timeout=].each { |method| http.define_singleton_method(method) { |_| } }
      http.define_singleton_method(:start) { starts += 1 }
      http.define_singleton_method(:started?) { false }
      http
    })
    error = assert_raises(Transport::ConfigurationError) do
      connection.perform(uri: URI(ENDPOINT), request: Net::HTTP::Post.new("/a2a"), response_limit: 100, guard: -> { },
        admission: -> { raise Transport::ConfigurationError.new(:admission) })
    end
    assert_equal 0, starts
    assert_not error.certainly_unsent?
  end

  test "post admission network-shaped exception propagates unchanged before first HTTP request" do
    calls = 0
    request_entered = false
    original = SocketError.new("synthetic admission interruption")
    http = Object.new
    %i[ipaddr= reply_byte_limit= use_ssl= verify_mode= verify_hostname= min_version= open_timeout= read_timeout= write_timeout= max_retries= keep_alive_timeout=].each { |method| http.define_singleton_method(method) { |_| } }
    http.define_singleton_method(:start) { }
    http.define_singleton_method(:started?) { false }
    http.define_singleton_method(:request) { |_| request_entered = true }
    connection = Transport::Connection.new(resolver: ->(_) { [ "8.8.8.8" ] }, http_factory: ->(_) { http })
    actual = assert_raises(SocketError) do
      connection.perform(uri: URI(ENDPOINT), request: Net::HTTP::Post.new("/a2a"), response_limit: 100, guard: -> { },
        admission: -> { calls += 1; raise original if calls == 2 })
    end
    assert_same original, actual
    assert_equal 2, calls
    assert_not request_entered
  end

  private

  def subscribe(provider, **overrides, &block)
    provider.subscribe(**{ url: ENDPOINT, resource: ENDPOINT, body: '{"method":"SubscribeToTask"}', token: "synthetic-token",
      admission: -> { true }, on_tick: -> { true }, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10 }.merge(overrides), &block)
  end

  def read_request(socket)
    header = +""
    header << socket.gets until header.end_with?("\r\n\r\n")
    length = header[/Content-Length: (\d+)/i, 1].to_i
    socket.read(length)
    header
  end

  def write_chunk(socket, chunk)
    socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
  end

  def with_listener(peer, &client)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      peer.call(socket)
    ensure
      socket&.close
    end
    http = LoopbackHTTP.new(server.addr[1], 443, nil)
    settings = { outbound_enabled: true, allowed_endpoints: [ { organization_id: "org", recipient_id: "recipient", endpoint_url: ENDPOINT, resource: ENDPOINT } ] }
    connection = Transport::Connection.new(resolver: ->(_host) { [ "8.8.8.8" ] }, http_factory: ->(_host) { http })
    provider = Transport.new(organization_id: "org", recipient_id: "recipient", purpose: :follow, settings: ->(key) { settings[key] }, connection: connection)
    client.call(provider, http)
    assert thread.join(3), "owned listener should see the client socket close"
    thread.value
  ensure
    thread&.kill if thread&.alive?
    thread&.join
    server&.close
  end
end

class A2a::NativeStreamTransportTest
  test "callback false closes before a withheld HTTP chunk terminator can block cleanup" do
    frame = "data: #{JSON.generate(jsonrpc: '2.0', id: 'rpc', result: { task: {} })}\n\n"
    with_listener(->(socket) do
      read_request(socket)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n#{frame.bytesize.to_s(16)}\r\n#{frame}")
      socket.read
    end) do |provider, http|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = subscribe(provider, deadline: started + 0.35) { false }
      assert_equal 200, response.status
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
      assert_not http.started?
    end
  end

  test "malformed frame after accepted base preserves its error despite missing HTTP chunk CRLF" do
    frame = "data: #{JSON.generate(jsonrpc: '2.0', id: 'rpc', result: { task: {} })}\n\ndata: not-json\n\n"
    with_listener(->(socket) do
      read_request(socket)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n#{frame.bytesize.to_s(16)}\r\n#{frame}")
      socket.read
    end) do |provider, http|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      observed = []
      error = assert_raises(Transport::Unconfirmed) do
        subscribe(provider, deadline: started + 0.35) { |event| observed << event; true }
      end
      assert_equal :stream_json, error.reason
      assert_nil error.cause
      assert_equal 1, observed.size
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
      assert_not http.started?
    end
  end
end
