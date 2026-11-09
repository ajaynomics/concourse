Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect, Concourse::Oidc.provider_options
end

# Only POST may begin the request phase. omniauth-rails_csrf_protection then
# enforces an authenticity token on it, which is what stops a third-party page
# from silently starting a sign-in.
OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true

# Never leak provider internals to the browser. Failures land on a route that
# renders a generic message.
OmniAuth.config.failure_raise_out_environments = []
