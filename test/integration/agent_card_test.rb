require "test_helper"

class AgentCardTest < ActionDispatch::IntegrationTest
  setup do
    owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    other = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    @ajay = Agent.create!(owner: owner, handle: "codex", oauth_client_id: "client-a", description: "Secret description")
    @riley = Agent.create!(owner: other, handle: "pi", oauth_client_id: "client-b")
  end

  test "the public card is spec-shaped, unauthenticated, and not reusable across agents" do
    get "/a2a/ajay/codex/.well-known/agent-card.json"
    assert_response :success
    ajay = response.parsed_body
    ajay_etag = response.headers["ETag"]

    assert_equal "ajay/codex", ajay["name"]
    assert_equal "An agent registered on Concourse.", ajay["description"]
    assert_equal [], ajay["skills"]
    assert_equal true, ajay.dig("capabilities", "streaming")
    assert_equal false, ajay.dig("capabilities", "pushNotifications")
    assert_equal true, ajay.dig("capabilities", "extendedAgentCard")
    assert_equal "JSONRPC", ajay.dig("supportedInterfaces", 0, "protocolBinding")
    assert_equal "1.0", ajay.dig("supportedInterfaces", 0, "protocolVersion")
    assert_equal "#{Concourse.app_url}/a2a/concourse/ajay/codex", ajay.dig("supportedInterfaces", 0, "url")
    issuer = Concourse.authorization_server
    scheme = ajay.dig("securitySchemes", "oauth2", "oauth2SecurityScheme")
    assert_equal "#{issuer}/oauth/authorize", scheme.dig("flows", "authorizationCode", "authorizationUrl")
    assert_equal "#{issuer}/oauth/token", scheme.dig("flows", "authorizationCode", "tokenUrl")
    assert_equal "#{issuer}/.well-known/oauth-authorization-server", scheme["oauth2MetadataUrl"]
    assert_equal [ "concourse" ], ajay.dig("securityRequirements", 0, "schemes", "oauth2", "list")
    assert_not ajay.key?("owner")
    assert_not response.body.include?("Secret description")
    assert_includes response.headers["Cache-Control"], "max-age="
    assert ajay_etag.present?

    get "/a2a/riley/pi/.well-known/agent-card.json"
    assert_not_equal ajay_etag, response.headers["ETag"]
    assert_equal "riley/pi", response.parsed_body["name"]
    assert_not response.body.include?("ajay/codex")

    get "/a2a/ajay/missing/.well-known/agent-card.json"
    assert_response :not_found
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  # The limit's store is the controller's cache store, fixed when the class
  # loads; in test that is a null store, so its count is set here.
  test "a client that asks for too many cards is turned away" do
    store = A2a::CardsController.cache_store
    store.define_singleton_method(:increment) { |*| 61 }

    get "/a2a/ajay/codex/.well-known/agent-card.json"
    assert_response :too_many_requests
  ensure
    store.singleton_class.remove_method(:increment)
  end

  test "the public card does not say when its agent was last active" do
    get "/a2a/ajay/codex/.well-known/agent-card.json"

    assert_nil response.headers["Last-Modified"]
    etag = response.headers["ETag"]
    @ajay.update!(last_seen_at: Time.current)
    get "/a2a/ajay/codex/.well-known/agent-card.json"
    assert_equal etag, response.headers["ETag"]
  end

  test "an older address without an organization leads to the legacy organization's agent" do
    legacy = Organization.create!(name: "Legacy")
    owner = User.create!(ajent_sub: "9", handle: "kim", organizations: [ legacy ])
    Agent.create!(owner: owner, organization: legacy, handle: "claude", oauth_client_id: "client-k")

    get "/a2a/kim/claude/.well-known/agent-card.json"
    assert_response :not_found

    with_config(:concourse, :legacy_organization, "legacy") do
      get "/a2a/kim/claude/.well-known/agent-card.json"
      assert_redirected_to "/a2a/legacy/kim/claude/.well-known/agent-card.json"
      follow_redirect!
      assert_equal "kim/claude", response.parsed_body["name"]

      get "/a2a/kim/nobody/.well-known/agent-card"
      assert_redirected_to "/a2a/legacy/kim/nobody/.well-known/agent-card"
      follow_redirect!
      assert_response :not_found

      get "/a2a/ajay/codex/.well-known/agent-card.json"
      assert_response :success, "the platform's own agents are still served there"
    end
  end

  private
    def with_config(service, key, value)
      previous = Rails.application.config.x.public_send(service)[key]
      Rails.application.config.x.public_send(service)[key] = value
      yield
    ensure
      Rails.application.config.x.public_send(service)[key] = previous
    end
end
