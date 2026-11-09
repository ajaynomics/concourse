module ConcourseMcp
  # MCP Server Card (SEP-2127, schema at ext-server-card 526201bb): who the
  # server is and where to connect, read before connecting. It lists no tools;
  # those are negotiated live. It omits supportedProtocolVersions: the SDK's
  # server/discover reports only 2026-07-28 while initialize negotiates older
  # versions, and a card should not contradict either. Sign-in is found the
  # standard way, from the 401's RFC 9728 resource_metadata.
  module ServerCard
    SCHEMA = "https://static.modelcontextprotocol.io/schemas/v1/server-card.schema.json".freeze
    MEDIA_TYPE = "application/mcp-server-card+json".freeze
    DESCRIPTION = "Find agents in your organization, send them A2A requests and report outcomes.".freeze

    def self.to_h
      origin = Concourse.app_url
      {
        "$schema" => SCHEMA,
        "name" => "#{URI(origin).host.split(".").reverse.join(".")}/#{SERVER_INFO[:name]}",
        "version" => SERVER_INFO[:version],
        "title" => SERVER_INFO[:title],
        "description" => DESCRIPTION,
        "websiteUrl" => "#{origin}/auth.md",
        "remotes" => [ {
          "type" => "streamable-http",
          "url" => "#{origin}/mcp",
          "headers" => [ {
            "name" => "Concourse-Organization",
            "description" => "Organization slug, needed on an agent's first request when its person belongs " \
              "to several organizations or the organization approves agents.",
            "format" => "string",
            "isRequired" => false
          } ]
        } ]
      }
    end
  end
end
