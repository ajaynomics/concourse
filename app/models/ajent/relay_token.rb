require "digest"
require "json"

module Ajent
  # RFC 6749 §4.4 / RFC 8707: a dedicated machine grant for ONE resource.
  # There is deliberately no caller-token, refresh-token or arbitrary URL input.
  class RelayToken
    SCOPE = "concourse:relay"
    EXPIRY_MARGIN = 30
    LIFETIME_CEILING = 300
    RESPONSE_LIMIT = 64.kilobytes
    TOKEN_LIMIT = 4096
    class Error < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("relay token #{reason}")
      end

      # Token/configuration failures say nothing about a native send's delivery.
      def certainly_unsent?
        false
      end
    end
    class ConfigurationError < Error; end
    class Rejected < Error; end
    class Unavailable < Error; end

    @cache = {}
    @locks = {}
    @mutex = Mutex.new

    def self.fetch(resource:)
      new(resource: resource).fetch
    end

    def self.clear_cache!
      @mutex.synchronize { @cache.clear }
    end

    def self.cached_token(key, now)
      @mutex.synchronize do
        entry = @cache[key]
        if entry && entry[:usable_until] > now
          entry[:token]
        else
          @cache.delete(key)
          nil
        end
      end
    end

    def self.cache_token(key, token, usable_until)
      @mutex.synchronize { @cache[key] = { token: token, usable_until: usable_until } }
    end

    def self.lock_for(key)
      @mutex.synchronize { @locks[key] ||= Mutex.new }
    end

    def initialize(resource:, settings: nil, connection: nil, clock: nil)
      @resource = resource
      @injected_settings = !settings.nil?
      @settings = settings || ->(key) { Rails.app.creds.option(:relay, key) }
      @connection = connection || A2a::NativeTransport::Connection.new
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    def fetch
      outbound_guard
      uri = A2a::NativeTransport.https_uri(@settings.call(:ajent_token_url))
      A2a::NativeTransport.https_uri(@resource)
      client_id, client_secret = credentials
      # A secret rotation or URL edit must not reuse an old grant. The digest
      # also keeps secrets out of cache keys; token values never leave memory.
      key = Digest::SHA256.hexdigest(JSON.generate([ uri.to_s, client_id, client_secret, @resource ]))
      Timeout.timeout(A2a::NativeTransport::TOTAL_TIMEOUT) do
        self.class.lock_for(key).synchronize do
          outbound_guard
          cached = self.class.cached_token(key, @clock.call)
          return cached if cached

          started_at = @clock.call
          request = Net::HTTP::Post.new(uri.request_uri)
          # RFC 6749 §2.3.1 encodes each credential before joining with ':'.
          request.basic_auth(URI.encode_www_form_component(client_id), URI.encode_www_form_component(client_secret))
          request["Accept"] = "application/json"
          request["Accept-Encoding"] = "gzip, deflate"
          request["Connection"] = "close"
          request.set_form_data("grant_type" => "client_credentials", "scope" => SCOPE, "resource" => @resource)
          response = @connection.perform(uri: uri, request: request, response_limit: RESPONSE_LIMIT, guard: method(:outbound_guard))
          token, lifetime = accept(response)
          now = @clock.call
          raise Unavailable.new(:expired) if started_at + lifetime <= now
          usable_until = started_at + lifetime - EXPIRY_MARGIN
          self.class.cache_token(key, token, usable_until) if usable_until > now
          token
        end
      end
    rescue A2a::NativeTransport::ConfigurationError
      raise ConfigurationError.new(:transport_policy), cause: nil
    rescue A2a::NativeTransport::Error, Timeout::Error
      raise Unavailable.new(:transport), cause: nil
    end

    private

    def credentials
      values = [ @settings.call(:relay_client_id), @settings.call(:relay_client_secret) ]
      unless values.all? { |value| value.is_a?(String) && value.bytesize.between?(1, TOKEN_LIMIT) && !value.match?(/[\x00-\x1f\x7f]/) && !value.strip.empty? }
        raise ConfigurationError.new(:credentials)
      end
      values
    end

    def outbound_guard
      raise ConfigurationError.new(:relay_incomplete) unless @injected_settings || A2a::NativeTransport.relay_complete?
      raise ConfigurationError.new(:outbound_disabled) unless @settings.call(:outbound_enabled).to_s == "true"
    end

    def accept(response)
      raise Rejected.new(:grant_rejected) if [ 400, 401, 403 ].include?(response.status)
      raise Unavailable.new(:status) unless response.status == 200
      raise Unavailable.new(:reply_limit) unless response.body.is_a?(String) && response.body.bytesize <= RESPONSE_LIMIT
      unless response.headers["content-type"].to_s.split(";").first.to_s.strip.downcase == "application/json"
        raise Unavailable.new(:content_type)
      end
      payload = JSON.parse(response.body)
      valid = payload.is_a?(Hash) && payload["token_type"].is_a?(String) && payload["token_type"].casecmp?("Bearer") && payload["scope"] == SCOPE && !payload.key?("refresh_token")
      token = payload["access_token"] if payload.is_a?(Hash)
      lifetime = payload["expires_in"] if payload.is_a?(Hash)
      valid &&= token.is_a?(String) && token.bytesize.between?(1, TOKEN_LIMIT) && token.match?(/\A[a-zA-Z0-9._~+\/-]+=*\z/)
      valid &&= lifetime.is_a?(Integer) && lifetime.between?(1, LIFETIME_CEILING)
      raise Unavailable.new(:grant_contract) unless valid

      [ token.freeze, lifetime ]
    rescue JSON::ParserError
      raise Unavailable.new(:grant_contract), cause: nil
    end
  end
end
