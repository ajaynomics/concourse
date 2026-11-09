require "test_helper"

class Ajent::RelayTokenTest < ActiveSupport::TestCase
  Provider = Ajent::RelayToken
  TOKEN_URL = "https://identity.example.test/oauth/token"
  RESOURCE = "https://native.example.test/a2a"

  class Connection
    attr_accessor :reply, :error, :on_request
    attr_reader :calls

    def initialize
      @calls = []
    end

    def perform(**arguments)
      arguments[:guard].call
      @calls << arguments
      @on_request&.call
      raise @error if @error
      @reply
    end
  end

  setup do
    Provider.clear_cache!
    @now = 1000.0
    @settings = {
      outbound_enabled: true,
      ajent_token_url: TOKEN_URL,
      relay_client_id: "concourse-relay",
      relay_client_secret: "synthetic-secret"
    }
    @connection = Connection.new
    @payload = { "access_token" => "relay-token", "token_type" => "Bearer", "expires_in" => 300, "scope" => "concourse:relay" }
    reply
  end

  teardown do
    Provider.clear_cache!
  end

  test "partial binary default settings cannot obtain machine credentials or tokens" do
    error = assert_raises(Provider::ConfigurationError) do
      Provider.new(resource: RESOURCE, connection: @connection).fetch
    end
    assert_equal :relay_incomplete, error.reason
    assert_not error.certainly_unsent?
    assert_empty @connection.calls
  end

  test "sends only the exact client credentials resource and relay scope grant to configured Ajent URL" do
    assert_equal "relay-token", provider.fetch
    call = @connection.calls.sole
    request = call[:request]
    assert_equal TOKEN_URL, call[:uri].to_s
    assert_equal "/oauth/token", request.path
    assert_equal "POST", request.method
    assert_equal "Basic #{Base64.strict_encode64("concourse-relay:synthetic-secret")}", request["Authorization"]
    assert_equal "application/x-www-form-urlencoded", request["Content-Type"]
    assert_equal({ "grant_type" => "client_credentials", "scope" => "concourse:relay", "resource" => RESOURCE }, URI.decode_www_form(request.body).to_h)
    assert_equal 3, URI.decode_www_form(request.body).length
    assert_equal Provider::RESPONSE_LIMIT, call[:response_limit]
    assert_equal "close", request["Connection"]
    assert_nil request["Cookie"]
    assert_nil request["Concourse-Caller"]
    assert_nil request["Concourse-Recipient"]
  end

  test "RFC 6749 section 2.3.1 form encodes credentials before Basic joining" do
    @settings[:relay_client_id] = "client:one"
    @settings[:relay_client_secret] = "space + secret:two"
    provider.fetch
    authorization = @connection.calls.sole[:request]["Authorization"]
    assert_equal "Basic #{Base64.strict_encode64("client%3Aone:space+%2B+secret%3Atwo")}", authorization
  end

  test "caller bearer refresh token and arbitrary token endpoint arguments do not exist" do
    assert_raises(ArgumentError) { Provider.fetch(resource: RESOURCE, caller_token: "caller-secret") }
    assert_raises(ArgumentError) { Provider.fetch(resource: RESOURCE, token_url: "https://evil.example.test/token") }
    assert_raises(ArgumentError) { Provider.new(resource: RESOURCE, refresh_token: "refresh-secret") }
    assert_empty @connection.calls
  end

  test "machine credentials cannot be sent to a native URL supplied as resource or response redirect" do
    assert_equal "relay-token", provider(resource: "https://other-native.example.test/a2a").fetch
    assert_equal TOKEN_URL, @connection.calls.sole[:uri].to_s
    reply(status: 302, headers: { "content-type" => "application/json", "location" => "https://evil.example.test/credentials" })
    error = assert_raises(Provider::Unavailable) { provider(resource: "https://third-native.example.test/a2a").fetch }
    assert_not error.certainly_unsent?
    assert_equal [ TOKEN_URL, TOKEN_URL ], @connection.calls.map { |call| call[:uri].to_s }
  end

  test "rejects missing credentials invalid Ajent URL resource and egress disabled without network" do
    [ nil, "", "   ", "bad\r\nsecret" ].each do |value|
      original = @settings[:relay_client_secret]
      @settings[:relay_client_secret] = value
      assert_raises(Provider::ConfigurationError) { provider.fetch }
      @settings[:relay_client_secret] = original
    end
    %w[http://identity.example.test/oauth/token https://id:secret@identity.example.test/oauth/token https://identity.example.test:8443/oauth/token https://identity.example.test/oauth/token?redirect=evil https://127.0.0.1/oauth/token].each do |url|
      @settings[:ajent_token_url] = url
      assert_raises(Provider::ConfigurationError) { provider.fetch }
    end
    @settings[:ajent_token_url] = TOKEN_URL
    assert_raises(Provider::ConfigurationError) { provider(resource: "https://native.example.test/a2a#fragment").fetch }
    @settings[:outbound_enabled] = false
    assert_raises(Provider::ConfigurationError) { provider.fetch }
    assert_empty @connection.calls
  end

  test "process cache spans instances and stops exactly thirty seconds before expiry" do
    assert_equal "relay-token", provider.fetch
    @now += 269
    assert_equal "relay-token", provider.fetch
    assert_equal 1, @connection.calls.length
    @now += 1
    reply(payload: @payload.merge("access_token" => "refreshed-token"))
    assert_equal "refreshed-token", provider.fetch
    assert_equal 2, @connection.calls.length
  end

  test "process cache is isolated by exact resource client URL and secret rotation" do
    provider.fetch
    provider(resource: "#{RESOURCE}/").fetch
    @settings[:relay_client_id] = "other-client"
    provider.fetch
    @settings[:relay_client_secret] = "rotated-synthetic-secret"
    provider.fetch
    @settings[:ajent_token_url] = "https://another-identity.example.test/oauth/token"
    provider.fetch
    assert_equal 5, @connection.calls.length
  end

  test "cache time begins before network latency not at successful response" do
    @connection.on_request = -> { @now += 9 }
    provider.fetch
    @now = 1270
    provider.fetch
    assert_equal 2, @connection.calls.length
  end

  test "short lived tokens are usable but never cached inside safety margin" do
    reply(payload: @payload.merge("expires_in" => 20))
    assert_equal "relay-token", provider.fetch
    assert_equal "relay-token", provider.fetch
    assert_equal 2, @connection.calls.length
  end

  test "expired in transit tokens are not returned or cached" do
    reply(payload: @payload.merge("expires_in" => 1))
    @connection.on_request = -> { @now += 2 }
    error = assert_raises(Provider::Unavailable) { provider.fetch }
    assert_equal :expired, error.reason
  end

  test "cached token is immutable and outbound off denies even a cached grant" do
    token = provider.fetch
    assert token.frozen?
    @settings[:outbound_enabled] = false
    assert_raises(Provider::ConfigurationError) { provider.fetch }
    assert_equal 1, @connection.calls.length
  end

  test "simultaneous same resource fetches make one grant request" do
    @connection.on_request = -> { Thread.pass }
    threads = Array.new(8) { Thread.new { provider.fetch } }
    assert_equal [ "relay-token" ] * 8, threads.map(&:value)
    assert_equal 1, @connection.calls.length
  end

  test "cached grant survives Ajent outage only until safety margin no stale rescue" do
    provider.fetch
    @connection.error = A2a::NativeTransport::Unavailable.new(:network, phase: :connecting)
    @now += 269
    assert_equal "relay-token", provider.fetch
    @now += 1
    error = assert_raises(Provider::Unavailable) { provider.fetch }
    assert_not error.certainly_unsent?
    assert_equal 2, @connection.calls.length
  end

  test "rejection unavailability and certificate policy errors never expose native fallback proof or provider text" do
    [ 400, 401, 403 ].each do |status|
      reply(status: status, body: "sensitive OAuth diagnostic")
      error = assert_raises(Provider::Rejected) { provider.fetch }
      assert_not error.certainly_unsent?
      assert_not_includes error.message, "sensitive"
    end
    reply(status: 503)
    assert_raises(Provider::Unavailable) { provider.fetch }
    @connection.error = A2a::NativeTransport::ConfigurationError.new(:tls_policy)
    error = assert_raises(Provider::ConfigurationError) { provider.fetch }
    assert_nil error.cause
    assert_not error.certainly_unsent?
    @connection.error = A2a::NativeTransport::Unconfirmed.new(:network, phase: :http)
    error = assert_raises(Provider::Unavailable) { provider.fetch }
    assert_nil error.cause
    assert_not error.certainly_unsent?
    @connection.error = Timeout::Error.new("secret diagnostic")
    error = assert_raises(Provider::Unavailable) { provider.fetch }
    assert_nil error.cause
    assert_not_includes error.message, "secret"
  end

  test "token contract fails closed for bad token type scope lifetime token value or refresh grant" do
    [
      @payload.merge("token_type" => "MAC"), @payload.merge("scope" => "concourse"),
      @payload.merge("scope" => "concourse:relay openid"), @payload.merge("scope" => [ "concourse:relay" ]),
      @payload.except("scope"), @payload.merge("expires_in" => 0), @payload.merge("expires_in" => 301),
      @payload.merge("expires_in" => "300"), @payload.merge("expires_in" => 300.5), @payload.except("expires_in"),
      @payload.merge("access_token" => ""), @payload.merge("access_token" => "bad\r\ntoken"),
      @payload.merge("access_token" => "x" * (Provider::TOKEN_LIMIT + 1)),
      @payload.merge("refresh_token" => "refresh-secret"), nil, [], "not-a-hash"
    ].each do |payload|
      reply(payload: payload)
      error = assert_raises(Provider::Unavailable) { provider.fetch }
      assert_equal :grant_contract, error.reason
      assert_not error.certainly_unsent?
      assert_nil error.cause
    end
    reply
    assert_equal "relay-token", provider.fetch
    assert_equal 18, @connection.calls.length
  end

  test "malformed non JSON or oversized response never enters token cache" do
    [
      { body: "{bad JSON" },
      { body: "x" * (Provider::RESPONSE_LIMIT + 1) },
      { headers: { "content-type" => "text/html" } }
    ].each do |options|
      reply(**options)
      assert_raises(Provider::Unavailable) { provider.fetch }
    end
    reply
    assert_equal "relay-token", provider.fetch
    assert_equal 4, @connection.calls.length
  end

  private

  def provider(resource: RESOURCE)
    Provider.new(resource: resource, settings: ->(key) { @settings[key] }, connection: @connection, clock: -> { @now })
  end

  def reply(status: 200, payload: @payload, body: nil, headers: { "content-type" => "application/json" })
    @connection.reply = A2a::NativeTransport::Response.new(status: status, body: body || JSON.generate(payload), headers: headers)
  end
end
