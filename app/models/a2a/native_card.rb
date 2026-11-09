require "digest"
require "json"
require "uri"

module A2a
  # Raw ProtoJSON, not SDK coercion: AgentCard/AgentInterface (§4.4.3/§4.4.6)
  # and OAuth/security requirements (§7.3, §8.3). Ownership/resource approval is
  # an operator contract, not a proprietary identity field in the public card.
  class NativeCard
    LIMIT = 256 * 1024
    INPUT_MODES = %w[text/plain application/json].freeze
    MEDIA_TYPE = /\A[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]{0,126}\/[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]{0,126}\z/
    SCOPE = "concourse:relay"
    FIELDS = %w[name description supportedInterfaces provider version documentationUrl capabilities securitySchemes securityRequirements defaultInputModes defaultOutputModes skills signatures iconUrl].freeze

    class Invalid < StandardError
      def initialize
        super("invalid native card")
      end
    end

    attr_reader :card, :digest, :revision

    def self.parse(body, **contract)
      raise Invalid unless body.is_a?(String) && body.bytesize.between?(1, LIMIT)
      text = body.dup.force_encoding(Encoding::UTF_8)
      raise Invalid unless text.valid_encoding?
      card = JSON.parse(text, max_nesting: 32, allow_nan: false, allow_duplicate_key: false)
      new(card, Digest::SHA256.hexdigest(body), **contract)
    rescue JSON::ParserError, ArgumentError, TypeError
      raise Invalid, cause: nil
    end

    def initialize(card, digest, endpoint_url:, resource:, tenant:, token_url:, oauth2_metadata_url:)
      @card, @digest = card, digest
      object!(card, FIELDS)
      string!(card["name"], 120)
      string!(card["description"], 4000)
      string!(card["version"], 120)
      @revision = card["version"]
      [ endpoint_url, resource, token_url, oauth2_metadata_url ].each { |url| url!(url) }
      interfaces = card["supportedInterfaces"]
      raise Invalid unless interfaces.is_a?(Array) && interfaces.size == 1
      interface = interfaces.first
      object!(interface, %w[url protocolBinding protocolVersion tenant])
      raise Invalid unless interface["url"] == endpoint_url && interface["protocolBinding"] == "JSONRPC" && interface["protocolVersion"] == "1.0"
      raise Invalid unless interface["tenant"] == tenant
      raise Invalid if tenant && (!tenant.is_a?(String) || !tenant.match?(/\A[a-zA-Z0-9._~-]{1,200}\z/))
      capabilities!(card["capabilities"])
      security!(token_url, oauth2_metadata_url)
      modes!(card["defaultInputModes"], input: true)
      modes!(card["defaultOutputModes"], input: false)
      skills!(card["skills"])
      raise Invalid if card.key?("signatures") && card["signatures"] != []
      %w[documentationUrl iconUrl].each { |key| descriptive_url!(card[key]) if card.key?(key) }
      if card.key?("provider")
        object!(card["provider"], %w[url organization])
        descriptive_url!(card["provider"]["url"])
        string!(card["provider"]["organization"], 120)
      end
      deep_freeze(card)
      @digest.freeze
      freeze
    end

    def streaming?
      card["capabilities"]["streaming"] == true
    end

    private

    def object!(value, keys)
      raise Invalid unless value.is_a?(Hash) && (value.keys - keys).empty?
    end

    def string!(value, limit = 4000)
      raise Invalid unless value.is_a?(String) && value.bytesize.between?(1, limit) && !value.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/)
    end

    def url!(value)
      uri = descriptive_url!(value)
      raise Invalid unless uri.query.nil? && uri.fragment.nil?
    end

    # Descriptive links (§4.4.3–4.4.4) are never outbound targets or fetched.
    def descriptive_url!(value)
      string!(value, 2048)
      uri = URI.parse(value)
      labels = uri.host.to_s.split(".", -1)
      host = labels.size >= 2 && labels.all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) } && labels.last.match?(/\A[a-z]+\z/)
      raise Invalid unless uri.is_a?(URI::HTTPS) && host && uri.port == 443 && uri.userinfo.nil?
      uri
    rescue URI::InvalidURIError
      raise Invalid, cause: nil
    end

    def capabilities!(value)
      object!(value, %w[streaming pushNotifications extendedAgentCard extensions])
      %w[streaming pushNotifications extendedAgentCard].each do |key|
        raise Invalid if value.key?(key) && ![ true, false ].include?(value[key])
      end
      return unless value.key?("extensions")
      raise Invalid unless value["extensions"].is_a?(Array)
      value["extensions"].each do |extension|
        object!(extension, %w[uri description required params])
        string!(extension["uri"], 2048)
        string!(extension["description"]) if extension.key?("description")
        raise Invalid if extension.key?("required") && extension["required"] != false
        raise Invalid if extension.key?("params") && !extension["params"].is_a?(Hash)
      end
    end

    def security!(token_url, metadata_url)
      schemes = card["securitySchemes"]
      raise Invalid unless schemes.is_a?(Hash) && schemes.size == 1
      @scheme_name = schemes.keys.first
      string!(@scheme_name, 120)
      scheme = schemes.values.first
      object!(scheme, %w[oauth2SecurityScheme])
      oauth = scheme["oauth2SecurityScheme"]
      object!(oauth, %w[description flows oauth2MetadataUrl])
      string!(oauth["description"]) if oauth.key?("description")
      raise Invalid unless oauth["oauth2MetadataUrl"] == metadata_url
      object!(oauth["flows"], %w[clientCredentials])
      flow = oauth["flows"]["clientCredentials"]
      object!(flow, %w[tokenUrl scopes])
      raise Invalid unless flow["tokenUrl"] == token_url && flow["scopes"].is_a?(Hash) && flow["scopes"].keys == [ SCOPE ]
      string!(flow["scopes"][SCOPE])
      requirements!(card["securityRequirements"])
    end

    def requirements!(value)
      raise Invalid unless value.is_a?(Array) && value.size == 1
      object!(value.first, %w[schemes])
      schemes = value.first["schemes"]
      raise Invalid unless schemes.is_a?(Hash) && schemes.keys == [ @scheme_name ]
      object!(schemes[@scheme_name], %w[list])
      raise Invalid unless schemes[@scheme_name]["list"] == [ SCOPE ]
    end

    def modes!(value, input:)
      raise Invalid unless value.is_a?(Array) && value.size.between?(1, 64) && value.uniq == value
      if input
        raise Invalid unless (value - INPUT_MODES).empty?
      else
        # Output declarations (§4.4.3/§4.4.5) do not expand request input or
        # authorize fetching file URLs. Concrete type/subtype names are bounded
        # by RFC 6838 §4.2; accepting a declaration is not an encoding proof.
        value.each do |mode|
          string!(mode, 255)
          raise Invalid unless mode.match?(MEDIA_TYPE)
        end
      end
    end

    def skills!(value)
      raise Invalid unless value.is_a?(Array)
      ids = []
      value.each do |skill|
        object!(skill, %w[id name description tags examples inputModes outputModes securityRequirements])
        %w[id name description].each { |key| string!(skill[key]) }
        raise Invalid unless skill["tags"].is_a?(Array)
        skill["tags"].each { |tag| string!(tag, 120) }
        if skill.key?("examples")
          raise Invalid unless skill["examples"].is_a?(Array)
          skill["examples"].each { |example| string!(example) }
        end
        modes!(skill["inputModes"], input: true) if skill.key?("inputModes")
        modes!(skill["outputModes"], input: false) if skill.key?("outputModes")
        requirements!(skill["securityRequirements"]) if skill.key?("securityRequirements")
        raise Invalid if ids.include?(skill["id"])
        ids << skill["id"]
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| key.freeze; deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end
end
