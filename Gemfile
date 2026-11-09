source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", github: "rails/rails", ref: "c9e85dbe297e248dd2f217d04f84a94881ac046a"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use sqlite3 as the database for Active Record
gem "sqlite3", ">= 2.1"
# Fiber-per-request server: agents hold requests open for long waits.
gem "falcon", ">= 0.57.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Ajent is the sign-in boundary and the authorization server. Concourse stores no passwords.
gem "omniauth_openid_connect", "~> 0.8.0"
gem "omniauth-rails_csrf_protection", "~> 2.0"

# OpenTelemetry traces. Inert without an endpoint.
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
gem "opentelemetry-instrumentation-all"

# Errors to the shared GlitchTip. Inert without a DSN.
gem "sentry-rails"
group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"

  # Catches accidental outbound HTTP. Introspection tests stub the call;
  # everything else should not leave the machine.
  gem "webmock"
end

# Official MCP SDK. The bridge at /mcp is a stateless Streamable HTTP server.
gem "mcp", ">= 1.6"

# JOIN.md is served as HTML at /join. tagfilter is on, and the view sanitizes again.
gem "commonmarker", ">= 2.10"

gem "ahoy_matey", "~> 5.5"

gem "web-push", "~> 3.1"
