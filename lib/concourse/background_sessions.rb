module Concourse
  class BackgroundSessions
    PATHS = %w[/service-worker /service-worker.js /manifest /manifest.json /cable].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      # expire_after renews even untouched cookies. A late background response
      # must not overwrite a newer sign-in, sign-out or setup continuation.
      # Keep the session readable and both twelve-hour expiry checks intact.
      if %w[GET HEAD].include?(env["REQUEST_METHOD"]) && PATHS.include?(env["PATH_INFO"])
        env.fetch("rack.session.options")[:skip] = true
      end
      @app.call(env)
    end
  end
end
