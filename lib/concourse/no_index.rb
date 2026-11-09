module Concourse
  # Crawlers must fetch private URLs to read noindex. Only approved public
  # HTML and its exact social image can opt out, in production only.
  class NoIndex
    HEADER = "noindex, nofollow, noarchive, nosnippet, noimageindex".freeze
    PUBLIC_HEADER = "x-concourse-public-page".freeze
    PUBLIC_PATHS = %w[/sign_in /join /terms /privacy].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      # These public files have stable URLs, unlike fingerprinted assets.
      if %w[/robots.txt /social-card.png].include?(env["PATH_INFO"]) &&
          %w[GET HEAD].include?(env["REQUEST_METHOD"]) && [ 200, 304 ].include?(status)
        headers["cache-control"] = "public, max-age=300, must-revalidate"
      end

      media_type = headers["content-type"].to_s.split(";").first
      public_page = headers.delete(PUBLIC_HEADER) == "true" &&
        PUBLIC_PATHS.include?(env["PATH_INFO"]) && media_type == "text/html"
      # A 304 updates cached headers without a new representation. Leave its
      # existing indexing policy intact, including static images without a type.
      return [ status, headers, body ] if status == 304

      social_image = env["PATH_INFO"] == "/social-card.png" && media_type == "image/png"
      indexable = Rails.env.production? && status == 200 &&
        %w[GET HEAD].include?(env["REQUEST_METHOD"]) && (public_page || social_image)
      headers["x-robots-tag"] = indexable ? "index, follow" : HEADER
      [ status, headers, body ]
    end
  end
end
