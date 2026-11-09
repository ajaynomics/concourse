require "uri"
require "ipaddr"

module Agent::NativeEndpoint
  extend ActiveSupport::Concern

  REGISTRATION_FIELDS = %w[native_endpoint_url native_card_url native_resource native_tenant].freeze
  CONTROL_FIELDS = %w[native_generation native_enabled native_discoverable native_verified_at native_verification native_card native_card_revision].freeze
  VERIFICATION_FIELDS = %w[native_verified_at native_verification native_card native_card_revision].freeze

  class VerificationError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("native card verification #{reason}")
    end
  end

  included do
    validate :native_endpoint_policy
    validate :native_route_not_locked, if: -> { persisted? && (organization_id_changed? || native_registration_changed?) }
    before_validation :invalidate_native_contract, if: :native_registration_changed?
  end

  class_methods do
    # Partial binaries cannot activate delivery by changing an environment value
    # or database column. Slices 4-6 and the Ajent gates must land first.
    def native_relay_complete?
      false
    end

    def native_relay_available?
      native_relay_complete?
    end

    def native_outbound_available?
      native_relay_complete? && Concourse.config(:relay, :outbound_enabled) == true
    end
  end

  def native_delivery_available?
    self.class.native_relay_available? && native_enabled? && native_verified_at? &&
      Concourse.config(:relay, :enabled) == true
  end

  def native_route_snapshot
    { endpoint_url: native_endpoint_url, resource: native_resource, tenant: native_tenant, generation: native_generation,
      native_streaming: native_verified_contract? && native_verification["streaming"] == true }
  end

  def native_route
    native_route_snapshot if native_delivery_available?
  end

  def register_native_endpoint!(endpoint_url:, card_url:, resource:, tenant: nil)
    with_lock do
      assign_attributes(native_endpoint_url: endpoint_url, native_card_url: card_url, native_resource: resource, native_tenant: tenant.presence)
      save!
    end
    self
  end

  def remove_native_endpoint!
    with_lock do
      assign_attributes(REGISTRATION_FIELDS.index_with { nil })
      save!
    end
    self
  end

  def native_registration
    attributes.slice(*(REGISTRATION_FIELDS + CONTROL_FIELDS))
  end

  def verify_native_endpoint!(owner:, transport: nil, settings: nil)
    # The explicit two-part seam is for synthetic providers only. No production
    # settings/credentials/provider construction precedes the completeness gate.
    unless transport && settings
      raise VerificationError.new(:relay_incomplete) unless self.class.native_relay_complete?
    end
    settings = native_card_settings(settings)
    raise VerificationError.new(:outbound_disabled) unless settings.call(:outbound_enabled).to_s == "true"
    pool = self.class.connection_pool
    raise VerificationError.new(:transaction_open) if pool.active_connection?&.transaction_open?
    captured = nil
    with_lock do
      check_native_verification_owner!(owner)
      check_native_verification_route!(settings)
      captured = attributes.slice("id", "owner_id", "organization_id", *REGISTRATION_FIELDS, "native_generation", *VERIFICATION_FIELDS)
    end
    # A pre-existing permanent lease must also be returned; never hold a DB
    # connection or transaction over the bounded public-card HTTP operation.
    pool.release_connection
    transport ||= A2a::NativeTransport.new(organization_id: captured.fetch("organization_id"), recipient_id: id)
    response = fetch_native_card(transport, captured)
    decoded = A2a::NativeCard.parse(response.body, endpoint_url: captured.fetch("native_endpoint_url"),
      resource: captured.fetch("native_resource"), tenant: captured["native_tenant"],
      token_url: settings.call(:ajent_token_url), oauth2_metadata_url: settings.call(:ajent_oauth2_metadata_url))
    with_lock do
      check_native_verification_owner!(owner)
      raise VerificationError.new(:stale_registration) unless captured == attributes.slice(*captured.keys)
      check_native_verification_route!(settings)
      @native_card_verifying, @native_card_settings = true, settings
      self.native_card = decoded.card
      self.native_card_revision = decoded.revision
      self.native_verified_at = Time.current
      self.native_verification = captured.slice("owner_id", "organization_id", *REGISTRATION_FIELDS).merge(
        "generation" => native_generation, "digest" => decoded.digest, "streaming" => decoded.streaming?)
      save!
    end
    self
  ensure
    @native_card_verifying = @native_card_settings = nil
  end

  def pending_relay_routes?
    tenant = Organization.find(organization_id_in_database || organization_id) # tenancy-ok: resolve this agent's persisted tenant before checking a move
    scope = tenant.relay_deliveries
    scope.where(caller_agent_id: id).or(
      scope.where(recipient_agent_id: id)
    ).pending.exists?
  end

  def native_route_locked?
    pending_relay_routes? || received_tasks.unfinished.where(execution_route: %w[native held]).exists?
  end

  private

  def native_registration_changed?
    REGISTRATION_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
  end

  def invalidate_native_contract
    self.native_generation = native_generation_in_database.to_i + 1
    self.native_verified_at = nil
    self.native_verification = {}
    self.native_card = {}
    self.native_card_revision = nil
    self.native_enabled = false
    self.native_discoverable = false
  end

  def native_route_not_locked
    errors.add(:base, "native route has pending work") if native_route_locked?
  end

  def native_endpoint_policy
    if persisted? && will_save_change_to_native_generation? && !native_registration_changed?
      errors.add(:native_generation, "generation changes only with registration")
    end
    if native_enabled? || native_discoverable?
      errors.add(:base, "native activation unavailable in this binary")
    end
    if !@native_card_verifying && VERIFICATION_FIELDS.any? { |field| will_save_change_to_attribute?(field) } && !native_registration_changed?
      errors.add(:base, "native card requires guarded verification")
    end
    return if REGISTRATION_FIELDS.all? { |field| public_send(field).blank? }

    unless [ native_endpoint_url, native_card_url, native_resource ].all? { |value| safe_native_url?(value) }
      errors.add(:base, "native routes require exact public HTTPS URLs")
      return
    end
    errors.add(:native_resource, "cannot be a gateway audience") if [ Concourse.app_url, "#{Concourse.app_url}/mcp" ].include?(native_resource)
    errors.add(:native_tenant, "invalid tenant") if native_tenant && !native_tenant.match?(/\A[a-zA-Z0-9._~-]{1,200}\z/)
    routes = @native_card_settings ? @native_card_settings.call(:allowed_endpoints) : Concourse.config(:relay, :allowed_endpoints)
    errors.add(:base, "native route requires operator approval") unless approved_native_route?(routes)
  rescue JSON::ParserError
    errors.add(:base, "invalid operator route configuration")
  end

  def native_card_settings(settings)
    return ->(key) { Rails.app.creds.option(:relay, key) } unless settings
    return settings if settings.respond_to?(:call)
    raise VerificationError.new(:settings) unless settings.is_a?(Hash)
    ->(key) { settings.key?(key) ? settings[key] : settings[key.to_s] }
  end

  def approved_native_route?(routes)
    if routes.is_a?(String)
      return false if routes.bytesize > 64.kilobytes
      routes = JSON.parse(routes)
    end
    routes.is_a?(Array) && routes.any? do |route|
      next false unless route.is_a?(Hash)
      route = route.stringify_keys
      route["organization_id"].to_s == organization_id.to_s && route["recipient_id"].to_s == id.to_s &&
        route["endpoint_url"] == native_endpoint_url && route["card_url"] == native_card_url &&
        route["resource"] == native_resource && route["tenant"] == native_tenant
    end
  end

  def check_native_verification_owner!(owner)
    unless owner.is_a?(User) && owner.id == owner_id && admitted?
      raise VerificationError.new(:owner_unadmitted)
    end
  end

  def check_native_verification_route!(settings)
    urls = [ native_endpoint_url, native_card_url, native_resource ]
    approved = urls.all? { |url| safe_native_url?(url) } && approved_native_route?(settings.call(:allowed_endpoints))
    approved &&= ![ Concourse.app_url, "#{Concourse.app_url}/mcp" ].include?(native_resource)
    approved &&= native_tenant.nil? || native_tenant.match?(/\A[a-zA-Z0-9._~-]{1,200}\z/)
    raise VerificationError.new(:route_unapproved) unless approved
    raise VerificationError.new(:outbound_disabled) unless settings.call(:outbound_enabled).to_s == "true"
  rescue JSON::ParserError
    raise VerificationError.new(:route_unapproved), cause: nil
  end

  def fetch_native_card(transport, captured)
    response = transport.get_card(url: captured.fetch("native_card_url"), resource: captured.fetch("native_resource"))
    unless response.status == 200 && response.headers.is_a?(Hash) && response.headers["content-type"].to_s.split(";", 2).first.to_s.strip.downcase == "application/json"
      raise VerificationError.new(:fetch_failed)
    end
    response
  rescue StandardError
    # Provider bodies, tokens, redirects and SDK exception text never escape.
    raise VerificationError.new(:fetch_failed), cause: nil
  end

  def native_verified_contract?
    native_verified_at.present? && native_card_revision.present? && native_card.present? &&
      native_verification["generation"] == native_generation &&
      native_verification["owner_id"] == owner_id && native_verification["organization_id"] == organization_id &&
      REGISTRATION_FIELDS.all? { |field| native_verification[field] == public_send(field) }
  end

  # Syntax is only admission policy, not a DNS/ownership/auth verification. No
  # connection occurs here; transport rechecks all DNS answers before any I/O.
  def safe_native_url?(value)
    return false unless value.is_a?(String) && value.bytesize <= 2048
    uri = URI.parse(value)
    return false unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.port == 443 && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
    return false if uri.path.blank? || !uri.host.match?(/\A[a-zA-Z0-9.-]+\z/) || !uri.host.include?(".")
    return false if uri.host.end_with?(".localhost", ".local", ".internal")
    begin
      IPAddr.new(uri.host)
      false
    rescue IPAddr::InvalidAddressError
      true
    end
  rescue URI::InvalidURIError
    false
  end
end
