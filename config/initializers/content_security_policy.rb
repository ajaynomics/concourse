# form-action must name the IdP's origin, not just 'self'. The sign-in form
# POSTs to /auth/ajent and OmniAuth answers with a 302 to the IdP, and
# Chrome checks a form submission's redirect target against form-action.
# With 'self' alone the browser blocks the very first click of sign-in.
#
# This policy block compiles while the application is still initializing,
# before lib/ is autoloadable, so it reads the config node directly, the same
# node Concourse::Oidc reads.
Rails.application.configure do
  issuer = config.x.oidc[:issuer].to_s
  oidc_origin = begin
    uri = URI.parse(issuer)
    uri.host.present? ? "#{uri.scheme}://#{uri.host}" : nil
  rescue URI::InvalidURIError
    nil
  end

  # Rybbit's script and its beacons. Read from the same node the layout renders
  # the tag from, so the two cannot disagree. Blank in development and test.
  analytics_host = config.x.analytics[:host].presence

  config.content_security_policy do |policy|
    policy.form_action :self, *[ oidc_origin ].compact
    policy.default_src :self
    policy.font_src :self, :data
    policy.img_src :self, :https, :data
    policy.object_src :none
    # :blob is Rybbit's replay worker.
    policy.script_src :self, :blob, *[ analytics_host ].compact
    policy.worker_src :self, :blob
    policy.manifest_src :self
    # style attributes (Turbo, the layout) need this. A nonce on style-src
    # would disable unsafe-inline in modern browsers and break those.
    policy.style_src :self, :unsafe_inline
    policy.connect_src :self, *[ analytics_host ].compact
    policy.frame_ancestors :none
    policy.base_uri :self
  end

  # Per request, so a nonce is never tied to a cookie.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
