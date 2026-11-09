module A2a
  class RpcController < ApiController
    def create
      result = Rpc.perform(
        caller_agent: Current.agent,
        recipient: recipient,
        body: request.raw_post,
        version: requested_version,
        content_type: request.media_type
      )
      if result.notification
        head :no_content
      elsif result.stream
        response.content_type = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        self.response_body = result.stream
      else
        render json: result.body
      end
    end

    private

    # Agents only call within their own organization. An address naming
    # another one, or an agent in another one, is not found (§13.1). The
    # older address names none, and means the caller's.
    def recipient
      organization_slug = path_param(:organization_slug)
      return if organization_slug && organization_slug != Current.organization.slug

      Current.organization.agents.named(path_param(:owner_handle), path_param(:agent_handle))
    end

    def path_param(key)
      request.path_parameters[key] || request.path_parameters[key.to_s]
    end

    # Header wins. A missing header may still arrive as a query parameter
    # (§3.6.1). An empty header is 0.3, not "look at the query string".
    def requested_version
      header = request.headers["A2A-Version"]
      return header unless header.nil?

      request.query_parameters["A2A-Version"]
    end
  end
end
