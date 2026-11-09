module Developer
  # A browser hint, not credentials or an assertion about the terminal's identity.
  class SetupContinuation
    SESSION_KEY = :developer_setup
    LIFETIME = 10.minutes
    STATE_FORMAT = /\A[A-Za-z0-9_-]{32,128}\z/
    PORT_FORMAT = /\A[1-9][0-9]{3,4}\z/

    attr_reader :port, :state, :expires_at

    def self.start(port:, state:)
      return unless valid_hints?(port, state)

      new(port: port, state: state, expires_at: LIFETIME.from_now.to_i)
    end

    def self.restore(value)
      return unless value.is_a?(Hash) && value.size == 3 && %w[expires_at port state].all? { |key| value.key?(key) }
      return unless valid_hints?(value["port"], value["state"])

      expiry = value["expires_at"]
      return unless expiry.is_a?(Integer) && expiry > Time.current.to_i && expiry <= LIFETIME.from_now.to_i

      new(port: value["port"], state: value["state"], expires_at: expiry)
    end

    def self.valid_hints?(port, state)
      port.is_a?(String) && port.match?(PORT_FORMAT) && port.to_i.between?(1024, 65535) &&
        state.is_a?(String) && state.match?(STATE_FORMAT)
    end
    private_class_method :valid_hints?

    def initialize(port:, state:, expires_at:)
      @port, @state, @expires_at = port, state, expires_at
    end

    def to_h
      { "port" => port, "state" => state, "expires_at" => expires_at }
    end

    def completion_url(organization)
      "http://127.0.0.1:#{port}/setup-complete?#{URI.encode_www_form(state: state, organization: organization.slug)}"
    end
  end
end
