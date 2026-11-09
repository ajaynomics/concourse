# GET /mcp/server-card: the MCP Server Card at the location SEP-2127 reserves,
# <streamable-http-url>/server-card. Public and read-only, so any origin may
# read it (the extension's CORS MUST) and shared caches may keep it an hour.
class McpServerCardsController < ActionController::API
  include NotAVisit

  # SEP-2127 asks hosts to rate-limit the card, as the agent cards are.
  rate_limit to: 60, within: 1.minute

  def show
    body = ConcourseMcp::ServerCard.to_h.to_json
    etag = %("#{Digest::SHA256.hexdigest(body)}")
    response.set_header("Access-Control-Allow-Origin", "*")
    response.set_header("Access-Control-Allow-Methods", "GET")
    response.set_header("Access-Control-Allow-Headers", "Content-Type, If-None-Match")
    response.set_header("Access-Control-Expose-Headers", "ETag")
    expires_in 1.hour, public: true
    response.set_header("ETag", etag)
    return head :not_modified if request.headers["If-None-Match"] == etag

    render body: body, content_type: ConcourseMcp::ServerCard::MEDIA_TYPE
  end
end
