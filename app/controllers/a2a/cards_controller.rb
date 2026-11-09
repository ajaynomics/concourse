module A2a
  # Public, unauthenticated. The URL is the cache key: each agent has its own
  # path, and the ETag is a hash of that agent's card, so a shared cache
  # cannot serve one agent another's card. Unauthenticated, so there is no
  # caller to take an organization from: the address names one. The older
  # address without one means the platform's own agents, and otherwise
  # redirects to the legacy organization's address.
  class CardsController < ActionController::API
    include NotAVisit

    # Public and answered 200 or 404, so unthrottled it would let anyone
    # list who and what is here.
    rate_limit to: 60, within: 1.minute

    def show
      agent = organization&.agents&.named(params[:owner_handle], params[:agent_handle])
      return redirect_to_legacy || render_missing unless agent

      body = Card.public_for(agent).to_json
      etag = %("#{Digest::SHA256.hexdigest(body)}")
      # No Last-Modified: the agent's updated_at moves whenever it is seen,
      # which would tell anyone when it was last active.
      response.set_header("Cache-Control", "public, max-age=#{Card::CACHE_MAX_AGE}")
      response.set_header("ETag", etag)
      return head :not_modified if request.headers["If-None-Match"] == etag

      render body: body, content_type: "application/json"
    end

    private

    def organization
      if params[:organization_slug]
        Organization.find_by(slug: params[:organization_slug]) # tenancy-ok: the address names the organization
      else
        Organization.default
      end
    end

    # Whether the agent exists there is the legacy address's to answer, so
    # this redirect says nothing about it.
    def redirect_to_legacy
      return if params[:organization_slug]

      legacy = Organization.legacy
      return unless legacy

      segments = [ legacy.slug, params[:owner_handle], params[:agent_handle] ].map { |segment| ERB::Util.url_encode(segment) }
      path = "/a2a/#{segments.join("/")}/.well-known/agent-card"
      path += ".json" if request.path.end_with?(".json")
      redirect_to path, status: :found
    end

    def render_missing
      response.set_header("Cache-Control", "private, no-store")
      head :not_found
    end
  end
end
