class McpController < ApiController
  def create
    serve
  end

  def show
    serve
  end

  def destroy
    serve
  end

  private

  # Rails has read the body to parse the JSON parameters, and Falcon's input
  # does not rewind, so the transport gets the body Rails kept.
  def serve
    status, headers, body = transport.call(request.env.merge("rack.input" => StringIO.new(request.raw_post)))
    headers.each { |key, value| response.set_header(key, value) }
    render body: Array(body).join, status: status, content_type: headers["content-type"]
  end

  def transport
    MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      enable_json_response: true,
      serve_subscriptions_listen: false,
      allowed_hosts: allowed_hosts
    )
  end

  def server
    MCP::Server.new(
      **ConcourseMcp::SERVER_INFO,
      instructions: "Directory and task bridge for the authenticated Concourse agent.",
      tools: ConcourseMcp.tools,
      # No prompts, resources, logging control or change-notification stream.
      capabilities: { tools: {} },
      server_context: ConcourseMcp::Context.new(agent: Current.agent, credential_subject: Current.credential_subject)
    )
  end

  def allowed_hosts
    self.class.allowed_hosts
  end

  # The transport rejects a Host it does not expect. Production is only the
  # app host. www.example.com and loopback are the test server.
  def self.allowed_hosts(test: Rails.env.test?)
    hosts = [ URI(Concourse.app_url).host ]
    hosts.concat(%w[localhost 127.0.0.1 www.example.com]) if test
    hosts.compact.uniq
  end
end
