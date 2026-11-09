require "test_helper"

class McpServerCardTest < ActionDispatch::IntegrationTest
  test "the server card is public SEP-2127 metadata for the /mcp endpoint" do
    assert_no_difference "Ahoy::Visit.count" do
      get "/mcp/server-card", headers: { "Accept" => ConcourseMcp::ServerCard::MEDIA_TYPE }
    end

    assert_response :success
    assert_equal "application/mcp-server-card+json", response.media_type
    assert_equal "max-age=3600, public", response.headers["cache-control"]
    assert_equal Concourse::NoIndex::HEADER, response.headers["x-robots-tag"]
    assert_equal "*", response.headers["access-control-allow-origin"]
    assert_equal "GET", response.headers["access-control-allow-methods"]
    assert_equal "ETag", response.headers["access-control-expose-headers"]

    card = JSON.parse(response.body)
    # The schema's required members, its pinned $schema and its name pattern.
    assert_equal "https://static.modelcontextprotocol.io/schemas/v1/server-card.schema.json", card["$schema"]
    assert_match %r{\A[a-zA-Z0-9.-]+/[a-zA-Z0-9._-]+\z}, card["name"]
    assert_equal "#{URI(Concourse.app_url).host.split(".").reverse.join(".")}/concourse", card["name"]
    assert_operator card["description"].length, :<=, 100
    assert_equal ConcourseMcp::SERVER_INFO[:version], card["version"]
    assert_equal ConcourseMcp::SERVER_INFO[:title], card["title"]
    assert_equal "#{Concourse.app_url}/auth.md", card["websiteUrl"]
    assert_equal [ { "type" => "streamable-http", "url" => "#{Concourse.app_url}/mcp" } ],
      card["remotes"].map { |remote| remote.slice("type", "url") }
    assert_equal [ "Concourse-Organization" ], card.dig("remotes", 0, "headers").map { |header| header["name"] }
    # No tools and no credentials: those come from the live connection and sign-in.
    assert_empty card.keys - %w[$schema name version title description websiteUrl remotes]
    assert_no_match(/token|secret/i, response.body)
  end

  test "an unchanged card revalidates with its ETag" do
    get "/mcp/server-card"
    etag = response.headers["etag"]
    assert etag.present?

    get "/mcp/server-card", headers: { "If-None-Match" => etag }

    assert_response :not_modified
    assert_equal "max-age=3600, public", response.headers["cache-control"]
  end

  test "the card's identity matches the server's serverInfo" do
    owner = User.create!(ajent_sub: "42", handle: "card-owner", email: "owner@card.test", organizations: [ Organization.default ])
    Agent.create!(owner: owner, oauth_client_id: "card-client")
    info = with_memory_cache do
      stub_agent_token("token-a", client_id: "card-client", sub: "42", email: "owner@card.test", resource: :mcp)
      post "/mcp", headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json, text/event-stream", "Authorization" => "Bearer token-a" },
        params: { jsonrpc: "2.0", id: 1, method: "initialize",
          params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" } } }.to_json
      assert_response :success
      response.parsed_body.dig("result", "serverInfo")
    end

    get "/mcp/server-card"
    card = JSON.parse(response.body)
    assert_equal info["version"], card["version"]
    assert_equal info["title"], card["title"]
    assert card["name"].end_with?("/#{info["name"]}")
  end
end
