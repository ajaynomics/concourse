# Central production configuration validation.
#
# One place, one error message. Per-service configuration stays a config_for
# line; required-secret checking belongs here so a missing value fails the
# boot loudly instead of surfacing as a nil deep inside a request.
REQUIRED_PRODUCTION_SECRETS = {
  app: %i[url],
  oidc: %i[issuer client_id client_secret],
  introspection: %i[client_id client_secret],
  glitchtip: %i[dsn]
}.freeze

Rails.application.config.after_initialize do
  # Asset precompile in the Docker build runs without real secrets.
  next if ENV["SECRET_KEY_BASE_DUMMY"]
  next unless Rails.env.production?

  missing = REQUIRED_PRODUCTION_SECRETS.flat_map do |service, keys|
    config = Rails.application.config.x.public_send(service)

    keys.filter_map do |key|
      value = config&.[](key)
      "config.x.#{service}.#{key} (see config/#{service}.yml)" if value.blank?
    end
  end

  next if missing.empty?

  raise <<~ERROR
    Missing required production configuration:
      #{missing.join("\n  ")}

    Each value resolves from ENV first, then Rails encrypted credentials.
  ERROR
end
