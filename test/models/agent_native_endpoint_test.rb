require "test_helper"

class AgentNativeEndpointTest < ActiveSupport::TestCase
  setup do
    @organization = Organization.default
    @elsewhere = Organization.create!(name: "Elsewhere")
    @owner = User.create!(ajent_sub: "native-owner", handle: "owner", organizations: [ @organization, @elsewhere ])
    @agent = Agent.create!(owner: @owner, handle: "native")
    @caller = Agent.create!(owner: @owner, handle: "caller")
    @previous = Rails.application.config.x.relay
    @route = { organization_id: @organization.id, recipient_id: @agent.id,
      endpoint_url: "https://native.example/a2a", card_url: "https://native.example/.well-known/agent-card.json",
      resource: "https://native.example/a2a" }
    Rails.application.config.x.relay = { allowed_endpoints: [ @route ], enabled: true, outbound_enabled: true }
  end

  teardown { Rails.application.config.x.relay = @previous }

  test "exact operator-approved registration stores a new generation but never verifies or enables" do
    register
    assert_equal 1, @agent.native_generation
    assert_nil @agent.native_verified_at
    assert_empty @agent.native_verification
    assert_not @agent.native_enabled?
    assert_not @agent.native_discoverable?
    assert_not @agent.native_delivery_available?
    assert_not Agent.native_relay_complete?
    assert_not Agent.native_outbound_available?
    assert_nil @agent.native_route
    assert_equal @route[:endpoint_url], @agent.native_route_snapshot[:endpoint_url]
    assert_not @agent.update(native_enabled: true)
    assert_not @agent.reload.update(native_discoverable: true)
    assert_not @agent.reload.update(native_verified_at: Time.current)
    @agent.reload.update_columns(native_enabled: true, native_verified_at: Time.current)
    assert_not @agent.reload.native_delivery_available?, "database/settings cannot enable a partial binary"
    assert_not_requested :any, /native\.example/
  end

  test "unapproved and unsafe URLs fail without outbound I/O" do
    [ "http://native.example/a2a", "https://127.0.0.1/a2a", "https://[::1]/a2a", "https://native.example:444/a2a",
      "https://native.example/a2a?token=x", "https://u:p@native.example/a2a", "https://native.example/a2a#x",
      "https://elsewhere.example/a2a", "https://metadata.internal/a2a" ].each do |url|
      assert_raises(ActiveRecord::RecordInvalid) { register(endpoint_url: url) }
      @agent.reload
    end
    assert_nil @agent.native_endpoint_url
    assert_not_requested :any, /example/
  end

  test "reserved inbox and native receipts block endpoint deletion replacement and organization moves" do
    register
    receipt = RelayDelivery.reserve!(caller: @caller, recipient: @agent,
      message: { "messageId" => "pending", "role" => "ROLE_USER", "parts" => [ { "text" => "pending" } ] })
    assert_raises(ActiveRecord::RecordInvalid) { @agent.remove_native_endpoint! }
    @agent.reload
    assert_not @agent.update(organization: @elsewhere)
    assert @agent.errors.added?(:organization, :open_tasks)
    @agent.reload
    assert_not @agent.update(native_endpoint_url: "https://changed.example/a2a")
    receipt.reject_reserved!(result: { "error" => "refused" })
    @agent.reload.remove_native_endpoint!
    assert_equal 2, @agent.native_generation
    assert_nil @agent.native_endpoint_url
  end

  test "held and unfinished native tasks lock registration even without an inbox item" do
    register
    Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @agent, execution_route: "held")
    assert_raises(ActiveRecord::RecordInvalid) { @agent.remove_native_endpoint! }
  end

  test "context mappings are party and generation scoped, bind once and cannot merge callers" do
    one = RelayContext.map!(caller: @caller, recipient: @agent, generation: 1, public_context_id: "public", native_context_id: "native")
    assert_equal one, RelayContext.map!(caller: @caller, recipient: @agent, generation: 1, public_context_id: "public", native_context_id: "native")
    assert_raises(RelayDelivery::Mismatch) { one.bind_native!("other") }
    assert_not one.update(caller_agent_id: @agent.id)
    other = RelayContext.map!(caller: @agent, recipient: @agent, generation: 1, public_context_id: "public", native_context_id: "native")
    assert_not_equal one, other
    newer = RelayContext.map!(caller: @caller, recipient: @agent, generation: 2, public_context_id: "public", native_context_id: "native")
    assert_not_equal one, newer
  end

  private

  def register(**options)
    @agent.register_native_endpoint!(**{ endpoint_url: @route[:endpoint_url], card_url: @route[:card_url], resource: @route[:resource] }.merge(options))
  end
end

class AgentNativeCardVerificationTest < ActiveSupport::TestCase
  # Verification deliberately refuses caller-owned transactions so card HTTP
  # cannot keep a transaction/DB lease alive. These constructors own all rows.
  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @organization = Organization.create!(name: "Native verification #{suffix}")
    @owner = User.create!(ajent_sub: "card-owner-#{suffix}", handle: "card-#{suffix}", organizations: [ @organization ])
    @agent = Agent.create!(owner: @owner, organization: @organization, handle: "native")
    @route = { organization_id: @organization.id, recipient_id: @agent.id, endpoint_url: "https://native.example/a2a",
      card_url: "https://native.example/.well-known/agent-card.json", resource: "https://native.example/a2a" }
    @settings = { outbound_enabled: true, allowed_endpoints: [ @route ], ajent_token_url: "https://issuer.example/oauth/token",
      ajent_oauth2_metadata_url: "https://issuer.example/.well-known/oauth-authorization-server" }
    @previous = Rails.application.config.x.relay
    Rails.application.config.x.relay = @settings
    @agent.register_native_endpoint!(endpoint_url: @route[:endpoint_url], card_url: @route[:card_url], resource: @route[:resource])
    @fetches = 0
  end

  teardown do
    Rails.application.config.x.relay = @previous
    @owner.destroy!
    @organization.destroy!
    Agent.connection_pool.release_connection
  end

  test "default provider is blocked before credentials settings construction and network" do
    credentials = Rails.app.creds
    original_option = credentials.method(:option)
    original_constructor = A2a::NativeTransport.method(:new)
    forbidden = ->(*) { flunk "credentials/settings/provider accessed" }
    begin
      credentials.define_singleton_method(:option, forbidden)
      A2a::NativeTransport.define_singleton_method(:new, forbidden)
      error = assert_raises(Agent::NativeEndpoint::VerificationError) { @agent.verify_native_endpoint!(owner: @owner) }
      assert_equal :relay_incomplete, error.reason
      assert_raises(Agent::NativeEndpoint::VerificationError) { @agent.verify_native_endpoint!(owner: @owner, settings: @settings) }
      assert_raises(Agent::NativeEndpoint::VerificationError) { @agent.verify_native_endpoint!(owner: @owner, transport: Object.new) }
    ensure
      credentials.define_singleton_method(:option, original_option)
      A2a::NativeTransport.define_singleton_method(:new, original_constructor)
    end
    assert_not Agent.native_relay_complete?
    assert_nil @agent.reload.native_verified_at
    assert_not_requested :any, /example/
  end

  test "verified card contract records bounded revision digest generation and streaming but never enables or publishes" do
    decoded_card = card
    assert_equal @agent, verify(provider(decoded_card))
    @agent.reload
    assert_equal decoded_card, @agent.native_card
    assert_equal "0.1.0", @agent.native_card_revision
    assert_equal Digest::SHA256.hexdigest(JSON.generate(decoded_card)), @agent.native_verification["digest"]
    assert_equal @agent.native_generation, @agent.native_verification["generation"]
    assert @agent.native_verified_at
    assert_equal true, @agent.native_route_snapshot[:native_streaming]
    assert_not @agent.native_enabled?
    assert_not @agent.native_discoverable?
    assert_not @agent.native_delivery_available?
    assert_nil @agent.native_route
    assert_not @agent.directory_entry.key?("nativeCardUrl")
    assert_equal 1, @fetches
    assert_not @agent.update(native_enabled: true)
    assert_not @agent.reload.update(native_discoverable: true)
    assert_not @agent.reload.update(native_card_revision: "manual")
  end

  test "A2A 4.4.3 and 4.4.5 verification accepts file outputs and descriptive links without fetching them" do
    body = card
    body["defaultOutputModes"] = %w[text/plain image/png application/pdf application/octet-stream]
    body["skills"] = [ { "id" => "files", "name" => "Files", "description" => "Native file output", "tags" => [ "files" ],
      "inputModes" => %w[text/plain application/json], "outputModes" => %w[image/png application/pdf application/octet-stream] } ]
    body["documentationUrl"] = "https://docs.example/agent#usage"
    body["iconUrl"] = "https://assets.example/icon.svg?v=1"
    body["provider"] = { "url" => "https://provider.example/?lang=en", "organization" => "Native provider" }
    assert_equal @agent, verify(provider(body))
    assert_equal body, @agent.reload.native_card
    assert_equal Digest::SHA256.hexdigest(JSON.generate(body)), @agent.native_verification["digest"]
    assert @agent.native_verified_at
    assert_equal 1, @fetches, "only the registered card is requested from the injected provider"
    assert_not_requested :any, /https?:\/\//
    assert_not Agent.native_relay_complete?
    assert_not @agent.native_delivery_available?
    assert_not @agent.native_enabled?
    assert_not @agent.native_discoverable?
    assert_not @agent.directory_entry.key?("nativeCardUrl")
  end

  test "non-streaming verified cards keep polling and editing invalidates all captured evidence" do
    body = card
    body["capabilities"]["streaming"] = false
    verify(provider(body))
    assert_equal false, @agent.reload.native_route_snapshot[:native_streaming]
    @agent.remove_native_endpoint!
    assert_nil @agent.native_verified_at
    assert_nil @agent.native_card_revision
    assert_empty @agent.native_card
    assert_empty @agent.native_verification
    assert_equal false, @agent.native_route_snapshot[:native_streaming]
  end

  test "wrong owner removed owner absent registration and allowlist mismatch cannot fetch" do
    error = assert_raises(Agent::NativeEndpoint::VerificationError) do
      @agent.verify_native_endpoint!(owner: User.new, transport: provider(card), settings: @settings)
    end
    assert_equal :owner_unadmitted, error.reason
    [ :resource, :card_url, :endpoint_url, :organization_id, :recipient_id, :tenant ].each do |key|
      settings = @settings.deep_dup
      settings[:allowed_endpoints].first[key] = "wrong"
      failure = assert_raises(Agent::NativeEndpoint::VerificationError) { @agent.verify_native_endpoint!(owner: @owner, transport: provider(card), settings: settings) }
      assert_equal :route_unapproved, failure.reason
    end
    @owner.memberships.where(organization: @organization).destroy_all
    assert_raises(Agent::NativeEndpoint::VerificationError) { verify(provider(card)) }
    assert_equal 0, @fetches
    assert_nil @agent.reload.native_verified_at
  end

  test "changed generation or route while fetching cannot verify stale data" do
    transport = provider(card) do
      other = @organization.agents.find(@agent.id)
      other.remove_native_endpoint!
      other.register_native_endpoint!(endpoint_url: @route[:endpoint_url], card_url: @route[:card_url], resource: @route[:resource])
    end
    error = assert_raises(Agent::NativeEndpoint::VerificationError) { verify(transport) }
    assert_equal :stale_registration, error.reason
    assert_equal 3, @agent.reload.native_generation
    assert_nil @agent.native_verified_at
    assert_not @agent.native_enabled?
  end

  test "removed owner during card fetch cannot verify or enable" do
    error = assert_raises(Agent::NativeEndpoint::VerificationError) do
      verify(provider(card) { @owner.memberships.where(organization: @organization).destroy_all })
    end
    assert_equal :owner_unadmitted, error.reason
    assert_nil @agent.reload.native_verified_at
    assert_empty @agent.native_card
    assert_not @agent.native_enabled?
  end

  test "a raced verification cannot overwrite a newer observed card" do
    newer = card
    newer["version"] = "0.2.0"
    newer["capabilities"]["streaming"] = false
    outer = provider(card) { verify(provider(newer)) }
    error = assert_raises(Agent::NativeEndpoint::VerificationError) { verify(outer) }
    assert_equal :stale_registration, error.reason
    assert_equal "0.2.0", @agent.reload.native_card_revision
    assert_equal false, @agent.native_route_snapshot[:native_streaming]
    assert_not @agent.native_enabled?
  end

  test "egress disable or operator revocation during fetch cannot store verification" do
    [ @settings, ->(key) { @settings[key] } ].each do |settings|
      [ -> { @settings[:outbound_enabled] = false }, -> { @settings[:allowed_endpoints] = [] } ].each do |change|
        @settings[:outbound_enabled], @settings[:allowed_endpoints] = true, [ @route ]
        assert_raises(Agent::NativeEndpoint::VerificationError) do
          @agent.verify_native_endpoint!(owner: @owner, transport: provider(card, &change), settings: settings)
        end
        assert_nil @agent.reload.native_verified_at
      end
    end
  end

  test "malformed oversized refused redirected and wrong-media card replies fail privately" do
    [ [ 200, "private-body", "application/json" ], [ 200, "x" * (A2a::NativeCard::LIMIT + 1), "application/json" ],
      [ 302, JSON.generate(card), "application/json" ], [ 401, "private-token", "application/json" ],
      [ 200, JSON.generate(card), "text/html" ] ].each do |status, body, media_type|
      error = assert_raises(A2a::NativeCard::Invalid, Agent::NativeEndpoint::VerificationError) do
        verify(provider(body, status: status, media_type: media_type))
      end
      assert_no_match(/private-body|private-token/, error.message)
      assert_nil error.cause
      assert_nil @agent.reload.native_verified_at
    end
    error = assert_raises(Agent::NativeEndpoint::VerificationError) do
      verify(provider(card) { raise "private-token provider-body" })
    end
    assert_equal "native card verification fetch_failed", error.message
    assert_nil error.cause
  end

  test "caller transaction is rejected before fetching rather than retaining a database lease" do
    Agent.transaction do
      error = assert_raises(Agent::NativeEndpoint::VerificationError) { verify(provider(card)) }
      assert_equal :transaction_open, error.reason
    end
    assert_equal 0, @fetches
  end

  private

  def verify(transport)
    @agent.verify_native_endpoint!(owner: @owner, transport: transport, settings: ->(key) { @settings[key] })
  end

  def provider(body, status: 200, media_type: "application/json", &during_fetch)
    body = JSON.generate(body) unless body.is_a?(String)
    implementation = ->(url:, resource:) do
      assert_equal @route[:card_url], url
      assert_equal @route[:resource], resource
      assert_nil Agent.connection_pool.active_connection?, "HTTP must own no DB lease"
      @fetches += 1
      during_fetch&.call
      A2a::NativeTransport::Response.new(status: status, body: body, headers: { "content-type" => media_type })
    end
    # The keyword-only seam admits no caller/task/delivery headers or bearer.
    test = self
    Object.new.tap do |transport|
      transport.define_singleton_method(:get_card) { |**args| test.instance_exec(**args, &implementation) }
    end
  end

  def card
    { "name" => "Independent native server", "description" => "A native test agent", "version" => "0.1.0",
      "supportedInterfaces" => [ { "url" => @route[:endpoint_url], "protocolBinding" => "JSONRPC", "protocolVersion" => "1.0" } ],
      "capabilities" => { "streaming" => true }, "defaultInputModes" => %w[text/plain application/json],
      "defaultOutputModes" => %w[text/plain application/json], "skills" => [],
      "securitySchemes" => { "native" => { "oauth2SecurityScheme" => { "oauth2MetadataUrl" => @settings[:ajent_oauth2_metadata_url],
        "flows" => { "clientCredentials" => { "tokenUrl" => @settings[:ajent_token_url], "scopes" => { "concourse:relay" => "Relay calls" } } } } } },
      "securityRequirements" => [ { "schemes" => { "native" => { "list" => [ "concourse:relay" ] } } } ] }
  end
end
