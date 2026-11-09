# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Message and artifact content. Parts are the A2A container; text, raw and
  # data are the part bodies. Rails hands this same list to Active Record, so
  # a column named parts is redacted in inspect as well as in the request log.
  # Message content must not leave the app in logs.
  :parts, :message, :text, :raw, :data,
  # Relay receipts and immutable events store whole wire bodies. SQL bind
  # logging must filter the column itself, not just nested part names.
  :payload, :native_task_id, :native_context_id, :native_artifact_id, :native_verification,
  :extensions, :reference_task_ids, :description, /\Aname\z/,
  # The OIDC callback arrives as a browser GET, so its query string is on the
  # request line Rails::Rack::Logger writes -- and that puts a live
  # authorization code in the log on every sign-in.
  #
  # Anchored, and not bare :code. Entries match on substring, so :code would
  # redact any diagnostic column whose name contains it.
  /\Acode\z/, /\Astate\z/,
  # A /connect code's PKCE verifier redeems the code; client_secret is
  # already caught by :secret.
  /\Acode_verifier\z/,
  # A Web Push endpoint is a capability URL, and its keys encrypt to the
  # browser. Anchored for the same reason as code.
  :endpoint, :p256dh, /\Aauth\z/
]
