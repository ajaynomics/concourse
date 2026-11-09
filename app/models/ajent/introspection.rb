module Ajent
  # RFC 7662 token introspection against Ajent.
  #
  # Human grants cache at most ten minutes; machine grants at most sixty
  # seconds, always bounded by expiry. Local binding/membership policy is
  # checked even on cache hits. Neither TTL bounds already-open streams.
  # An inactive answer is cached for a minute so a stream of made-up bearer
  # tokens cannot turn each request into a call to the issuer.
  class Introspection
    class Rejected < StandardError; end
    # Ajent itself was just asked and said inactive: the one rejection that
    # cost an issuer call, so the only one callers count against an address.
    class Inactive < Rejected; end
    class Unavailable < StandardError; end

    CACHE_CEILING = 10.minutes
    MACHINE_CACHE_CEILING = 60.seconds
    INACTIVE_CACHE_TTL = 60.seconds
    INACTIVE = { "active" => false }.freeze
    SCOPE = "concourse"

    def self.authenticate(token, audience:)
      new(token, audience: audience).authenticate
    end

    # RFC 7662 makes sub optional. This issuer's machine profile omits human
    # identity entirely; no private agent claim or downgrade to user admission.
    def self.validate_machine!(payload)
      raise Rejected unless payload["client_id"].is_a?(String) && payload["client_id"].present?
      raise Rejected unless payload["scope"] == SCOPE
      raise Rejected if %w[sub username email name token_use agent].any? { |key| payload.key?(key) }
      raise Rejected unless payload["exp"].is_a?(Integer) && payload["exp"] > Time.current.to_i
      audiences = payload["aud"].is_a?(Array) ? payload["aud"] : [ payload["aud"] ]
      raise Rejected unless audiences.one? && audiences.first.is_a?(String) && audiences.first.present?
    end

    def initialize(token, audience:)
      @token = token.to_s
      @audience = audience.to_s
    end

    def authenticate
      cached = read_cache
      return accept!(cached) if cached

      payload = fetch
      if payload.is_a?(Hash) && payload["active"] == true
        accepted = accept!(payload)
        write_cache(payload)
        accepted
      elsif payload.is_a?(Hash) && payload["active"] == false
        # RFC 7662 §2.2: an inactive token is expired, revoked or never
        # issued, and none of those becomes active again. Only that answer is
        # cached; an active token refused here, by audience or binding, may
        # pass after a local change, and an outage (Unavailable) is never
        # cached at all.
        write_inactive_cache
        raise Inactive
      else
        # Neither active nor inactive is not an answer to remember or count.
        raise Rejected
      end
    end

    private

    def fetch
      uri = introspection_uri
      Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 2,
        read_timeout: 3
      ) do |http|
        request = Net::HTTP::Post.new(uri)
        request.basic_auth(client_id, client_secret)
        request["Accept"] = "application/json"
        request.set_form_data("token" => @token)
        response = http.request(request)
        raise Unavailable, "status #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end
    rescue JSON::ParserError, Timeout::Error, EOFError, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError
      raise Unavailable
    end

    def accept!(payload)
      raise Rejected unless payload.is_a?(Hash)
      raise Rejected unless payload["active"] == true
      raise Rejected unless payload["client_id"].is_a?(String) && payload["client_id"].present?
      if Agent::ClientBinding.machine_payload?(payload)
        self.class.validate_machine!(payload)
        raise Rejected unless audience_ok?(payload["aud"])
        binding = Agent::ClientBinding.for_client(payload["client_id"])
        raise Rejected unless binding
        binding.admitted_agent!
      else
        raise Rejected if payload.key?("agent") || (payload.key?("token_use") && payload["token_use"] != "user")
        raise Rejected unless audience_ok?(payload["aud"])
        raise Rejected unless scope_ok?(payload["scope"])
        raise Rejected if payload["sub"].blank? || expired?(payload)
      end

      payload
    end

    # RFC 7662 aud is a string or an array. The expected resource must be
    # present exactly: a trailing slash is a different resource, and a token
    # issued for /mcp is not a token for the app URL.
    def audience_ok?(aud)
      Array(aud).map(&:to_s).include?(@audience)
    end

    def scope_ok?(scope)
      scopes = scope.is_a?(Array) ? scope.map(&:to_s) : scope.to_s.split(/\s+/)
      scopes.include?(SCOPE)
    end

    def expired?(payload)
      exp = payload["exp"]
      return false if exp.blank?

      exp.to_i <= Time.current.to_i
    end

    def write_cache(payload)
      ttl = cache_ttl(payload)
      return if ttl <= 0

      Rails.cache.write(cache_key, payload, expires_in: ttl)
    end

    def cache_ttl(payload)
      exp = payload["exp"]
      return 0 if exp.blank?

      remaining = exp.to_i - Time.current.to_i
      ceiling = payload["sub"].blank? ? MACHINE_CACHE_CEILING : CACHE_CEILING
      [ remaining, ceiling.to_i ].min
    end

    def read_cache
      Rails.cache.read(cache_key)
    end

    def write_inactive_cache
      Rails.cache.write(cache_key, INACTIVE, expires_in: INACTIVE_CACHE_TTL)
    end

    # The token itself is never the key. A cache dump must not be a token dump.
    def cache_key
      "ajent/introspection/#{Digest::SHA256.hexdigest(@token)}"
    end

    def introspection_uri
      URI("#{Concourse.authorization_server}/oauth/introspect")
    end

    def client_id
      Concourse.config(:introspection, :client_id).to_s
    end

    def client_secret
      Concourse.config(:introspection, :client_secret).to_s
    end
  end
end
