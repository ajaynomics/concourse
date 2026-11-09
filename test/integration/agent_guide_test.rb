require "test_helper"

class AgentGuideTest < ActionDispatch::IntegrationTest
  test "auth.md explains discovery, sign-in and the three interfaces from this origin" do
    assert_no_difference "Ahoy::Visit.count" do
      get "/auth.md"
    end

    assert_response :success
    assert_equal "text/markdown", response.media_type
    assert_equal "max-age=300, public", response.headers["cache-control"]
    assert_equal Concourse::NoIndex::HEADER, response.headers["x-robots-tag"]
    body = response.body
    assert body.start_with?("# Concourse for agents\n"), "no blank lines before the title"
    assert_includes body, "#{Concourse.app_url}/.well-known/oauth-protected-resource"
    assert_includes body, "#{Concourse.app_url}/.well-known/oauth-protected-resource/mcp"
    assert_includes body, "#{Concourse.authorization_server}/.well-known/oauth-authorization-server"
    # RFC 8707: the two exact resources, each in backticks so nothing else matches.
    assert_includes body, "exactly\n  `#{Concourse.app_url}` for A2A and REST"
    assert_includes body, "exactly `#{Concourse.app_url}/mcp` for MCP"
    assert_includes body, "Scope: exactly `concourse`"
    assert_includes body, "(`S256`)"
    assert_includes body, "invalid_target"
    assert_includes body, "#{Concourse.authorization_server}/oauth/concourse_v3/registrations"
    assert_includes body, '"method": "SendMessage"'
    assert_includes body, '"returnImmediately": true'
    assert_includes body, "/api/events?wait=25"
    assert_includes body, "PUT #{Concourse.app_url}/api/events/cursor"
    assert_includes body, "PATCH #{Concourse.app_url}/tasks/<task_id>"
    assert_includes body, "/api/push_config"
    assert_includes body, "REPLY_REQUIRED"
    assert_includes body, "https://gitea.ajay.to/ajaynomics/concourse-clients"
    assert_includes body, "script/concourse-v3 join --agent"
    assert_includes body, "script/concourse-v3 callback --url"
    assert_includes body, "#{Concourse.app_url}/connect?response_type=code"
    assert_includes body, "code_challenge_method=S256"
    assert_includes body, "-X POST #{Concourse.app_url}/connect/token"
    assert_includes body, "POST #{Concourse.app_url}/connect/revoke"
    # Every MCP tool the guide names is one the server registers.
    ConcourseMcp.tools.each { |tool| assert_includes body, "`#{tool.name_value}`" }
  end

  test "auth.md describes Concourse, not any organization on it" do
    tenant = Organization.create!(name: "Private Tenant", guide_note: "Private guide content")

    get "/auth.md"

    assert_response :success
    assert_not_includes response.body, tenant.slug
    assert_not_includes response.body, "Private guide content"
  end

  test "llms.txt indexes the guide and the machine documents as plain text" do
    assert_no_difference "Ahoy::Visit.count" do
      get "/llms.txt"
    end

    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_equal "max-age=300, public", response.headers["cache-control"]
    assert_equal Concourse::NoIndex::HEADER, response.headers["x-robots-tag"]
    body = response.body
    # llmstxt.org: an H1 name, then a blockquote summary.
    assert_match(/\A# Concourse\n\n> /, body)
    assert_includes body, "](#{Concourse.app_url}/auth.md)"
    assert_includes body, "](#{Concourse.app_url}/.well-known/oauth-protected-resource)"
    assert_includes body, "](#{Concourse.app_url}/.well-known/oauth-protected-resource/mcp)"
    assert_includes body, "](#{Concourse.authorization_server}/.well-known/oauth-authorization-server)"
    assert_includes body, "](#{Concourse.app_url}/mcp/server-card)"
  end

  test "auth.md and llms.txt are fixed platform paths, not organization pages" do
    assert_includes Organization::RESERVED_SLUGS, "auth"
    assert_includes Organization::RESERVED_SLUGS, "llms"
    assert_no_match Organization::SLUG_FORMAT, "auth.md"
    assert_no_match Organization::SLUG_FORMAT, "llms.txt"
  end

  # A2A §8.3: advertise only what is implemented. Concourse is not one agent,
  # and each organization's network agent has its own card.
  test "there is no root agent card" do
    get "/.well-known/agent-card.json"

    assert_response :not_found
  end
end
