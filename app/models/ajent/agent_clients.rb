module Ajent
  # Ajent stays the only issuer. When a member approves an app at /connect,
  # Concourse asks Ajent to mint one confidential client_credentials client
  # for the new agent, and to revoke it when the agent is retired. This wraps
  # those two calls and nothing else; the caller is Concourse's own
  # "Concourse agent joins" client, never a person's token.
  class AgentClients
    class Error < StandardError; end
    class NotConfigured < Error; end
    # Ajent refused the request: our credential (401), a reused key (409) or
    # the owner (422, including the per-owner client cap). Retrying will not help.
    class Rejected < Error; end
    # Outage, or an answer outside the contract.
    class Unavailable < Error; end

    Client = Data.define(:client_id, :client_secret, :owner_sub) do
      # A logged or printed client must not carry its secret.
      def inspect
        "#<data #{self.class.name} client_id=#{client_id.inspect}, client_secret=[FILTERED], owner_sub=#{owner_sub.inspect}>"
      end
      alias_method :to_s, :inspect

      def pretty_print(printer)
        printer.text(inspect)
      end
    end

    NETWORK_ERRORS = [ Timeout::Error, EOFError, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError ].freeze
    REFUSALS = [ 400, 401, 403, 409, 422 ].freeze

    def self.configured?
      [ Concourse.authorization_server, client_id, client_secret ].all?(&:present?)
    end

    def self.client_id
      Concourse.config(:ajent, :agent_clients_client_id).to_s
    end

    def self.client_secret
      Concourse.config(:ajent, :agent_clients_client_secret).to_s
    end

    # One Idempotency-Key per mint. A lost answer is retried once with the
    # same key and the same body, so Ajent returns the client it already made
    # (with a new secret) rather than a second one. A changed body never
    # reuses a key.
    def mint(owner_sub:, name:)
      raise NotConfigured unless self.class.configured?

      key = SecureRandom.uuid
      body = { owner_sub: owner_sub, name: name }.to_json
      attempts = 0
      begin
        attempts += 1
        client_from(post(body, key))
      rescue Unavailable
        retry if attempts < 2
        raise
      end
    end

    # 404 is gone too: already revoked, or never ours.
    def revoke(client_id)
      raise NotConfigured unless self.class.configured?

      status = request(Net::HTTP::Delete.new(uri("/#{ERB::Util.url_encode(client_id)}"))).code.to_i
      return true if [ 204, 404 ].include?(status)
      raise Rejected, "status #{status}" if REFUSALS.include?(status)

      raise Unavailable, "status #{status}"
    end

    private

    def post(body, key)
      http_request = Net::HTTP::Post.new(uri)
      http_request["Content-Type"] = "application/json"
      http_request["Idempotency-Key"] = key
      http_request.body = body
      request(http_request)
    end

    def client_from(response)
      status = response.code.to_i
      raise Rejected, "status #{status}" if REFUSALS.include?(status)
      raise Unavailable, "status #{status}" unless [ 200, 201 ].include?(status)

      payload = JSON.parse(response.body.to_s)
      raise Unavailable, "contract" unless payload.is_a?(Hash)

      client_id, client_secret, owner_sub = payload.values_at("client_id", "client_secret", "owner_sub")
      valid = client_id.is_a?(String) && client_id.match?(/\A\S{1,255}\z/) &&
        client_secret.is_a?(String) && client_secret.present? && owner_sub.is_a?(String)
      raise Unavailable, "contract" unless valid

      # The owner is checked against the agent's owner when the binding is
      # made (Agent::ClientBinding), which also revokes a mismatched client.
      Client.new(client_id: client_id, client_secret: client_secret, owner_sub: owner_sub)
    rescue JSON::ParserError
      raise Unavailable, "contract"
    end

    def request(http_request)
      target = http_request.uri
      # RFC 6749 §2.3.1 encodes each credential before joining with ':'.
      http_request.basic_auth(URI.encode_www_form_component(self.class.client_id), URI.encode_www_form_component(self.class.client_secret))
      http_request["Accept"] = "application/json"
      Net::HTTP.start(target.host, target.port, use_ssl: target.scheme == "https", open_timeout: 2, read_timeout: 5, max_retries: 0) do |http|
        http.request(http_request)
      end
    rescue *NETWORK_ERRORS
      raise Unavailable, "network"
    end

    def uri(suffix = "")
      URI("#{Concourse.authorization_server}/oauth/concourse_v3/agent_clients#{suffix}")
    end
  end
end
