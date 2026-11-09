require "test_helper"

class Ajent::AgentClientsTest < ActiveSupport::TestCase
  URL = "http://www.example.com/oauth/concourse_v3/agent_clients"

  setup do
    @settings = Rails.application.config.x.ajent
    @previous = @settings.to_h.dup
    @settings.agent_clients_client_id = "concourse joins"
    @settings.agent_clients_client_secret = "s:cret"
  end

  teardown do
    @settings.agent_clients_client_id = @previous[:agent_clients_client_id]
    @settings.agent_clients_client_secret = @previous[:agent_clients_client_secret]
  end

  test "unconfigured settings refuse before any call" do
    @settings.agent_clients_client_id = ""
    assert_not Ajent::AgentClients.configured?
    assert_raises(Ajent::AgentClients::NotConfigured) { mint }
    assert_raises(Ajent::AgentClients::NotConfigured) { Ajent::AgentClients.new.revoke("minted") }
  end

  test "mint posts the owner and name with encoded basic auth and an idempotency key" do
    stub_request(:post, URL).to_return(status: 201, body: { client_id: "minted", client_secret: "secret", owner_sub: "42" }.to_json)
    client = mint
    assert_equal [ "minted", "secret", "42" ], [ client.client_id, client.client_secret, client.owner_sub ]
    assert_requested(:post, URL, body: { owner_sub: "42", name: "App as org/kim/app" }.to_json) do |request|
      request.headers["Authorization"] == "Basic #{Base64.strict_encode64('concourse+joins:s%3Acret')}" &&
        request.headers["Content-Type"] == "application/json" && request.headers["Idempotency-Key"].present?
    end
  end

  test "a lost answer is retried once with the same key and body; a refusal is not retried" do
    keys = []
    stub_request(:post, URL).with { |request| keys << request.headers["Idempotency-Key"] }
      .to_return({ status: 502 }, { status: 200, body: { client_id: "minted", client_secret: "new", owner_sub: "42" }.to_json })
    assert_equal "minted", mint.client_id
    assert_equal 2, keys.size
    assert_equal 1, keys.uniq.size

    [ 401, 409, 422 ].each do |status|
      WebMock.reset!
      stub_request(:post, URL).to_return(status: status, body: "{}")
      assert_raises(Ajent::AgentClients::Rejected) { mint }
      assert_requested :post, URL, times: 1
    end
  end

  test "a minted client never shows its secret when printed" do
    client = Ajent::AgentClients::Client.new(client_id: "minted", client_secret: "do-not-print", owner_sub: "42")
    [ client.inspect, client.to_s, client.pretty_inspect, [ client ].inspect ].each do |text|
      assert_not_includes text, "do-not-print"
      assert_includes text, "client_secret=[FILTERED]"
      assert_includes text, "minted"
    end
    assert_equal "do-not-print", client.client_secret
  end

  test "answers outside the contract are unavailable" do
    [ "not json", "[]", { client_id: "has space", client_secret: "s", owner_sub: "42" }.to_json,
      { client_id: "minted", client_secret: "", owner_sub: "42" }.to_json, { client_id: "minted", client_secret: "s", owner_sub: 42 }.to_json ].each do |body|
      WebMock.reset!
      stub_request(:post, URL).to_return(status: 201, body: body)
      assert_raises(Ajent::AgentClients::Unavailable) { mint }
    end
  end

  test "revoke treats 204 and 404 as gone" do
    stub_request(:delete, "#{URL}/minted%20id").to_return({ status: 204 }, { status: 404 }, { status: 401 }, { status: 500 })
    clients = Ajent::AgentClients.new
    assert clients.revoke("minted id")
    assert clients.revoke("minted id")
    assert_raises(Ajent::AgentClients::Rejected) { clients.revoke("minted id") }
    assert_raises(Ajent::AgentClients::Unavailable) { clients.revoke("minted id") }
  end

  private

  def mint
    Ajent::AgentClients.new.mint(owner_sub: "42", name: "App as org/kim/app")
  end
end
