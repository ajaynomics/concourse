Rails.application.config.middleware.insert_after ActionDispatch::Session::CookieStore, Concourse::BackgroundSessions
