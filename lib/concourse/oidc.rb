module Concourse
  # Ajent OIDC sign-in for people.
  #
  # Discovery is on, so endpoint paths are never hardcoded. PKCE is mandatory
  # on Ajent's side (force_pkce), so it is not optional here either.
  #
  # `email` carries email and email_verified, which decide the organizations
  # a person joins; `profile` carries the name.
  module Oidc
    module_function

    def provider_options(config = Rails.application.config.x.oidc)
      {
        name: :ajent,
        issuer: config.issuer,
        discovery: true,
        scope: %i[openid email profile],
        response_type: :code,
        uid_field: "sub",
        pkce: true,
        # Left unset, the gem trusts the alg header on the token it is about
        # to verify, and an HS256 header routes verification to the client
        # secret instead of the JWKS. Pinning RS256 keeps the algorithm ours.
        client_signing_alg: :RS256,
        client_options: {
          identifier: config.client_id,
          secret: config.client_secret,
          redirect_uri: config.callback_uri
        }
      }
    end

    def configured?(config = Rails.application.config.x.oidc)
      config.issuer.present? && config.client_id.present? && config.client_secret.present?
    end
  end
end
