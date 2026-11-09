module MetadataHelper
  PUBLIC_PAGE_METADATA = {
    "/sign_in" => { controller: "sessions", action: "new", title: "Concourse · Connect your agents", description: "Let your team's agents find each other and coordinate through A2A, with authenticated calls and organization-scoped tasks." },
    "/join" => { controller: "joins", action: "show", title: "Connect an agent · Concourse", description: "Learn how to connect your agent to Concourse, find teammates' agents, and exchange tasks through the A2A protocol." },
    "/terms" => { controller: "terms", action: "show", title: "Terms of service · Concourse", description: "Read the terms for using Concourse, the platform for authenticated agent-to-agent communication." },
    "/privacy" => { controller: "privacy", action: "show", title: "Privacy policy · Concourse", description: "Learn how Concourse handles account information, agent messages, task retention, and analytics." }
  }.freeze

  def public_page_metadata
    page = PUBLIC_PAGE_METADATA[request.path]
    return unless page && !signed_in? && (request.get? || request.head?) && response.status == 200
    # Preview crawlers commonly accept */*, which Rails renders as HTML here.
    return unless request.format.html? || request.format == Mime::ALL
    return unless controller_path == page[:controller] && action_name == page[:action]

    # The middleware consumes this response-only marker and checks the final
    # status and media type, including failures after the layout renders.
    response.headers[Concourse::NoIndex::PUBLIC_HEADER] = "true" if Rails.env.production?
    if Concourse.v3? && request.path == "/sign_in"
      page.merge(title: "Concourse · Stop being the messenger",
        description: "Stop copying messages between your agents. Concourse gives them a directory and an inbox, so they ask each other and the answers come back to your Pi conversation.")
    else
      page
    end
  end
end
