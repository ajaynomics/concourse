config = Rails.application.config.x.glitchtip

# Production requires the DSN (production_secrets.rb fails the boot without it),
# so this guard is what keeps development, test and the asset-precompile build
# from initialising Sentry at all.
if config.dsn.present?
  Sentry.init do |sentry|
    sentry.dsn = config.dsn
    sentry.environment = ENV.fetch("DEPLOYMENT_ENVIRONMENT", Rails.env.to_s)
    sentry.release = Concourse.revision
    # Falcon runs many requests on one thread; per-thread scope would put one
    # request's user and breadcrumbs on another's error.
    sentry.hub_isolation_level = :fiber

    # Rails 8's error reporter is the idiomatic entry point; this subscribes
    # Sentry to it so Rails.error.report reaches GlitchTip, and picks up the
    # exceptions Rails rescues internally rather than only the ones that
    # escape to a 500.
    sentry.rails.register_error_subscriber = true
    sentry.rails.report_rescued_exceptions = true
    # :http_logger is deliberately absent. It patches Net::HTTP and attaches
    # the request body to a breadcrumb. One of those calls is token
    # introspection, whose body is the access token.
    sentry.breadcrumbs_logger = [ :active_support_logger ]

    # No request bodies and no stack-frame locals. A JSON-RPC body's keys are
    # jsonrpc/id/method/params, so filter_parameters never sees
    # params.message.parts[].text. Useful context is the route, the method,
    # and agent ids, set when the request is authenticated.
    Concourse::Glitchtip.apply(sentry)
    sentry.max_breadcrumbs = 100

    # Traces already go to the shared cell over OTLP; this is errors only.
    sentry.traces_sample_rate = 0.0
  end
end

# sentry-rails declares its Action Cable connection hooks private, and Rails
# 8.2 calls handle_open and handle_close on the connection directly, so every
# /cable connection fails. Delete this once sentry-rails ships the fix
# (getsentry/sentry-ruby#2975); it does nothing to a release that has it.
ActiveSupport.on_load(:action_cable_connection) do
  Sentry::Rails::ActionCableExtensions::Connection.module_eval do
    public :handle_open, :handle_close if private_method_defined?(:handle_open)
  end
end
