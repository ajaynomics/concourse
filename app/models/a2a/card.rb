module A2a
  # Public card is what a client needs before it holds a credential (§7.3):
  # handle, JSON-RPC interface, OAuth scheme. Description, skills, owner, and
  # harness are on the extended card (§3.1.11, §13.3). Owner and
  # harness travel as an AgentExtension's params: the card itself carries only
  # AgentCard fields, because clients parse it strictly against the proto.
  class Card
    PROTOCOL_VERSION = "1.0"
    AGENT_VERSION = "1.0.0"
    PUBLIC_DESCRIPTION = "An agent registered on Concourse."
    SCOPE_DESCRIPTION = "Call agents registered on Concourse."
    MODES = %w[text/plain application/json].freeze
    CACHE_MAX_AGE = 60

    def self.public_for(agent)
      new(agent, extended: false).to_h
    end

    def self.extended_for(agent)
      new(agent, extended: true).to_h
    end

    def self.endpoint_url(agent)
      "#{Concourse.app_url}/a2a/#{agent.organization.slug}/#{agent.prefix}/#{agent.handle}"
    end

    def initialize(agent, extended:)
      @agent = agent
      @extended = extended
    end

    def to_h
      {
        "name" => qualified_handle,
        "description" => description,
        "supportedInterfaces" => [ interface ],
        "version" => AGENT_VERSION,
        "capabilities" => capabilities,
        "securitySchemes" => security_schemes,
        "securityRequirements" => security_requirements,
        "defaultInputModes" => MODES,
        "defaultOutputModes" => MODES,
        "skills" => skills
      }
    end

    private

    def qualified_handle
      @agent.qualified_handle
    end

    def description
      return PUBLIC_DESCRIPTION unless @extended

      @agent.description.presence || PUBLIC_DESCRIPTION
    end

    def interface
      {
        "url" => self.class.endpoint_url(@agent),
        "protocolBinding" => "JSONRPC",
        "protocolVersion" => PROTOCOL_VERSION
      }
    end

    def capabilities
      body = {
        "streaming" => true,
        "pushNotifications" => false,
        "extendedAgentCard" => true
      }
      body["extensions"] = [ membership_extension ] if @extended
      body
    end

    def membership_extension
      params = { "organization" => @agent.organization.slug, "owner" => @agent.owner.handle }
      params["namespace"] = @agent.namespace.name if @agent.namespace
      params["harness"] = @agent.harness if @agent.harness.present?
      params["name"] = @agent.name if @agent.name.present?
      params["projects"] = @agent.project_slugs if @agent.projects.any?
      {
        "uri" => "#{Concourse.app_url}/extensions/membership",
        "description" => "Organization, owner, namespace, harness, and projects of this Concourse agent.",
        "params" => params
      }
    end

    def skills
      listed = Array(@agent.skills).filter_map { |skill| skill_hash(skill) }
      # The public card stays skill-less so a stranger learns nothing about
      # someone's agent. The conformance agent is a published SUT: the TCK
      # reads this card, and CARD-STRUCT-001 expects a skills array the
      # reference SUT fills.
      return listed if @extended || conformance_agent?

      []
    end

    def conformance_agent?
      @agent.handle == Conformance::HANDLE && @agent.owner.handle == User::SYSTEM_HANDLE
    end

    def skill_hash(skill)
      hash = skill.to_h.stringify_keys
      return if hash["id"].blank? || hash["name"].blank? || hash["description"].blank?

      tags = Array(hash["tags"]).map(&:to_s).reject(&:blank?)
      return if tags.empty?

      {
        "id" => hash["id"].to_s,
        "name" => hash["name"].to_s,
        "description" => hash["description"].to_s,
        "tags" => tags
      }.tap do |out|
        examples = Array(hash["examples"]).map(&:to_s).reject(&:blank?)
        out["examples"] = examples if examples.any?
        input_modes = Array(hash["inputModes"] || hash["input_modes"]).map(&:to_s).reject(&:blank?)
        out["inputModes"] = input_modes if input_modes.any?
        output_modes = Array(hash["outputModes"] || hash["output_modes"]).map(&:to_s).reject(&:blank?)
        out["outputModes"] = output_modes if output_modes.any?
      end
    end

    def security_schemes
      issuer = Concourse.authorization_server
      {
        "oauth2" => {
          "oauth2SecurityScheme" => {
            "description" => "OAuth 2.0 authorization code with PKCE.",
            "flows" => {
              "authorizationCode" => {
                "authorizationUrl" => "#{issuer}/oauth/authorize",
                "tokenUrl" => "#{issuer}/oauth/token",
                "scopes" => { "concourse" => SCOPE_DESCRIPTION },
                "pkceRequired" => true
              }
            },
            "oauth2MetadataUrl" => "#{issuer}/.well-known/oauth-authorization-server"
          }
        }
      }
    end

    def security_requirements
      [ { "schemes" => { "oauth2" => { "list" => [ "concourse" ] } } } ]
    end
  end
end
