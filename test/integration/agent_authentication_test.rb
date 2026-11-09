require "test_helper"

class AgentAuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    @token = "access-token-1"
    @payload = {
      "active" => true,
      "scope" => "concourse",
      "client_id" => "client-1",
      "sub" => "42",
      "aud" => "https://concourse.example.com",
      "exp" => 10.minutes.from_now.to_i,
      "email" => "ajay@example.com"
    }
    @user = User.find_or_create_from_subject!(ajent_sub: "42", email: "ajay@example.com")
    Organization.default.memberships.create!(user: @user)
  end

  test "a missing token is 401 without error, pointing at the protected resource" do
    get api_identity_path

    assert_unauthorized token_presented: false
    assert_equal "#{Concourse.app_url}/.well-known/oauth-protected-resource", metadata_url
  end

  test "a presented token Ajent rejects is 401 invalid_token" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.merge("active" => false).to_json,
        headers: { "Content-Type" => "application/json" }
      )

      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }

      assert_unauthorized token_presented: true
    end
  end

  test "a token without a subject is 401 invalid_token, same as an inactive token" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.merge("sub" => "").to_json,
        headers: { "Content-Type" => "application/json" }
      )

      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }

      assert_unauthorized token_presented: true
      assert_nil Agent.find_by(oauth_client_id: "client-1")
    end
  end

  test "a valid token establishes the owner and an unnamed agent" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.to_json, headers: { "Content-Type" => "application/json" }
      )

      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }

      assert_response :success
      body = response.parsed_body
      agent = Agent.find(body["agent_id"])
      assert_equal "client-1", agent.oauth_client_id
      assert_nil agent.handle
      assert_nil body["handle"]
      assert_equal "42", agent.owner.ajent_sub
      assert_equal agent.owner.id, body["owner_id"]
      assert_equal agent.owner.handle, body["owner"]
    end
  end

  test "Ajent being down with nothing cached is 503, not invalid_token" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_timeout

      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }

      assert_response :service_unavailable
      assert_equal "30", response.headers["Retry-After"]
      assert_equal "unavailable", response.parsed_body["error"]
      assert_not_includes response.headers["WWW-Authenticate"].to_s, "invalid_token"
    end
  end

  test "an Ajent outage on JSON-RPC is 503 with a JSON-RPC body" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_timeout

      post "/a2a/riley/pi",
        params: { jsonrpc: "2.0", id: "outage-1", method: "GetTask", params: {} }.to_json,
        headers: { "Authorization" => "Bearer #{@token}", "CONTENT_TYPE" => "application/json" }

      assert_response :service_unavailable
      assert_equal "30", response.headers["Retry-After"]
      assert_equal "2.0", response.parsed_body["jsonrpc"]
      assert_equal "outage-1", response.parsed_body["id"]
      assert_equal(-32603, response.parsed_body.dig("error", "code"))
      assert_not_includes response.headers["WWW-Authenticate"].to_s, "invalid_token"

      post "/mcp",
        params: { jsonrpc: "2.0", id: 7, method: "initialize" }.to_json,
        headers: { "Authorization" => "Bearer #{@token}", "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

      assert_response :service_unavailable
      assert_equal 7, response.parsed_body["id"]
      assert_equal(-32603, response.parsed_body.dig("error", "code"))
    end
  end

  test "a cached token still works when Ajent is unreachable" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.to_json, headers: { "Content-Type" => "application/json" }
      )
      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
      assert_response :success

      stub_request(:post, "http://www.example.com/oauth/introspect").to_timeout
      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
      assert_response :success
    end
  end

  test "a token for the wrong resource is 401" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.merge("aud" => "#{Concourse.app_url}/mcp").to_json,
        headers: { "Content-Type" => "application/json" }
      )
      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
      assert_unauthorized token_presented: true

      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.merge("aud" => "#{Concourse.app_url}/").to_json,
        headers: { "Content-Type" => "application/json" }
      )
      get api_identity_path, headers: { "Authorization" => "Bearer trailing" }
      assert_unauthorized token_presented: true

      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200,
        body: @payload.merge("aud" => [ "https://other.example", "#{Concourse.app_url}/" ]).to_json,
        headers: { "Content-Type" => "application/json" }
      )
      get api_identity_path, headers: { "Authorization" => "Bearer array-slash" }
      assert_unauthorized token_presented: true
    end
  end

  test "an array audience is accepted when it contains the endpoint resource exactly" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200,
        body: @payload.merge("aud" => [ "https://other.example", Concourse.app_url ]).to_json,
        headers: { "Content-Type" => "application/json" }
      )
      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
      assert_response :success

      stub_request(:post, "http://www.example.com/oauth/introspect").with(body: hash_including("token" => "mcp-token")).to_return(
        status: 200,
        body: @payload.merge("aud" => [ "#{Concourse.app_url}/mcp" ]).to_json,
        headers: { "Content-Type" => "application/json" }
      )
      post "/mcp", params: "{}", headers: {
        "Authorization" => "Bearer mcp-token",
        "CONTENT_TYPE" => "application/json",
        "ACCEPT" => "application/json"
      }
      assert_not_equal 401, response.status
    end
  end

  test "a token cached for the app url is still rejected on mcp" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.to_json, headers: { "Content-Type" => "application/json" }
      )
      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
      assert_response :success

      post "/mcp", params: "{}", headers: {
        "Authorization" => "Bearer #{@token}",
        "CONTENT_TYPE" => "application/json",
        "ACCEPT" => "application/json"
      }
      assert_response :unauthorized
      assert_includes response.headers["WWW-Authenticate"], %(error="invalid_token")
      assert_includes response.headers["WWW-Authenticate"], "/.well-known/oauth-protected-resource/mcp"
    end
  end

  test "a good token for someone in no organization is 403 and says to sign in on the web" do
    @user.memberships.destroy_all
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.to_json, headers: { "Content-Type" => "application/json" }
      )

      assert_no_difference -> { Agent.count } do
        get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
      end
      assert_response :forbidden
      assert_equal "not_a_member", response.parsed_body["error"]
      assert_includes response.parsed_body["message"], "Sign in on the web at #{Concourse.app_url}"
      assert_nil response.headers["WWW-Authenticate"]

      post "/a2a/riley/pi", params: { jsonrpc: "2.0", id: "req-9", method: "GetTask", params: { id: "x" } }.to_json,
        headers: { "Authorization" => "Bearer #{@token}", "CONTENT_TYPE" => "application/json", "A2A-Version" => "1.0" }
      assert_response :forbidden
      assert_equal "req-9", response.parsed_body["id"]
      assert_includes response.parsed_body.dig("error", "message"), Concourse.app_url
    end
  end

  test "removing someone from the organization stops their agent there" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.to_json, headers: { "Content-Type" => "application/json" }
      )
      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
      assert_response :success
      assert_equal "concourse", response.parsed_body["organization"]

      @user.memberships.destroy_all
      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
      assert_response :forbidden

      # A membership elsewhere does not carry an agent across organizations.
      Organization.create!(name: "Elsewhere").memberships.create!(user: @user)
      get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
      assert_response :forbidden
    end
  end

  test "distinct made-up tokens from one address are turned away after the limit without asking Ajent" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: { active: false }.to_json, headers: { "Content-Type" => "application/json" }
      )
      limit = AgentAuthentication::FAILED_BEARER_LIMIT
      limit.times do |index|
        get api_identity_path, headers: { "Authorization" => "Bearer random-#{index}" }
        assert_unauthorized token_presented: true
      end
      assert_requested :post, "http://www.example.com/oauth/introspect", times: limit

      post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
        headers: { "Authorization" => "Bearer random-next", "CONTENT_TYPE" => "application/json" }
      assert_response :too_many_requests
      assert_equal "60", response.headers["Retry-After"]
      assert_requested :post, "http://www.example.com/oauth/introspect", times: limit

      # Another address is unaffected, and the window passes.
      get api_identity_path, headers: { "Authorization" => "Bearer other" }, env: { "REMOTE_ADDR" => "198.51.100.20" }
      assert_unauthorized token_presented: true
      travel 61.seconds do
        get api_identity_path, headers: { "Authorization" => "Bearer later" }
        assert_unauthorized token_presented: true
      end
    end
  end

  test "a good token does not count toward the failure limit" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.to_json, headers: { "Content-Type" => "application/json" }
      )
      (AgentAuthentication::FAILED_BEARER_LIMIT + 1).times do
        get api_identity_path, headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :success
      end
    end
  end

  # One stale client behind a shared home address must not lock out the rest.
  test "a revoked token repeated from one address asks Ajent once and never counts" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: { active: false }.to_json, headers: { "Content-Type" => "application/json" }
      )
      40.times do
        get api_identity_path, headers: { "Authorization" => "Bearer revoked" }
        assert_unauthorized token_presented: true
      end
      assert_requested :post, "http://www.example.com/oauth/introspect", times: 1
    end
  end

  test "an active token refused locally never counts toward the limit" do
    with_memory_cache do
      stub_request(:post, "http://www.example.com/oauth/introspect").to_return(
        status: 200, body: @payload.merge("aud" => "https://elsewhere.example").to_json,
        headers: { "Content-Type" => "application/json" }
      )
      40.times do |index|
        get api_identity_path, headers: { "Authorization" => "Bearer elsewhere-#{index}" }
        assert_unauthorized token_presented: true
      end
    end
  end

  test "mcp paths advertise the mcp protected-resource document" do
    header = AgentAuthentication.www_authenticate(path: "/mcp", token_presented: true)

    assert_includes header, %(resource_metadata="#{Concourse.app_url}/.well-known/oauth-protected-resource/mcp")
    assert_includes header, %(error="invalid_token")
    assert_not_includes AgentAuthentication.www_authenticate(path: "/api/identity", token_presented: false), "error="
  end

  private

  def assert_unauthorized(token_presented:)
    assert_response :unauthorized
    header = response.headers["WWW-Authenticate"]
    assert_includes header, %(resource_metadata="#{Concourse.app_url}/.well-known/oauth-protected-resource")
    assert_includes header, %(scope="concourse")
    if token_presented
      assert_includes header, %(error="invalid_token")
    else
      assert_not_includes header, "error="
    end
  end

  def metadata_url
    response.headers["WWW-Authenticate"][/resource_metadata="([^"]+)"/, 1]
  end
end
