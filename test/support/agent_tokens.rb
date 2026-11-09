module AgentTokens
  INTROSPECT = "http://www.example.com/oauth/introspect"

  # Concourse admits people on the web, never from a token, so the person
  # behind the token is made a member here, of the default organization
  # unless the test names another or nil.
  def stub_agent_token(token, client_id:, sub:, email: "#{sub}@example.com", resource: :app, username: nil, organization: Organization.default)
    if organization
      user = User.find_or_create_from_subject!(ajent_sub: sub, email: username || email)
      organization.memberships.find_or_create_by!(user: user)
    end
    aud = resource == :mcp ? "#{Concourse.app_url}/mcp" : Concourse.app_url
    stub_request(:post, INTROSPECT).with(body: hash_including("token" => token)).to_return(
      status: 200,
      body: {
        "active" => true,
        "scope" => "concourse",
        "client_id" => client_id,
        "sub" => sub,
        "aud" => aud,
        "exp" => 30.minutes.from_now.to_i,
        "email" => email,
        "username" => username || email
      }.compact.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  # The agent's address names its organization; organization: nil is the
  # older address without one.
  def rpc(owner:, agent:, method:, params: {}, token:, version: "1.0", content_type: "application/json", organization: Organization.default)
    headers = { "CONTENT_TYPE" => content_type, "Authorization" => "Bearer #{token}" }
    headers["A2A-Version"] = version unless version.nil?
    post [ "/a2a", organization&.slug, owner, agent ].compact.join("/"),
      params: { jsonrpc: "2.0", id: "req-1", method: method, params: params }.to_json,
      headers: headers
    response.parsed_body
  end

  def mcp_call(token, name, arguments = {})
    post "/mcp",
      params: {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: name, arguments: arguments }
      }.to_json,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "ACCEPT" => "application/json",
        "Authorization" => "Bearer #{token}"
      }
    response.parsed_body
  end
end

module EventCapture
  Capture = Struct.new(:events) do
    def emit(event)
      events << event
    end
  end

  def capture_events(name = nil)
    capture = Capture.new([])
    Rails.event.subscribe(capture) { |event| name.nil? || event[:name] == name }
    yield capture.events
  end
end
