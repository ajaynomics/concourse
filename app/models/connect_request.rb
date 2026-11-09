# What a web app asks for when it sends a person to /connect: an RFC 6749
# §4.1.1 authorization request with PKCE S256 (RFC 7636), plus the agent it
# proposes. Nothing here is trusted until it validates, and an invalid request
# is never redirected anywhere (RFC 6749 §4.1.2.1).
class ConnectRequest
  include ActiveModel::Model
  include ActiveModel::Attributes

  FIELDS = %i[response_type redirect_uri state code_challenge code_challenge_method handle name app_name].freeze
  SESSION_KEY = :connect_request
  # Long enough to sign in, short enough that a stale request does not
  # reappear after an unrelated sign-in later.
  LIFETIME = 10.minutes
  # BASE64URL(SHA256(verifier)) without padding is always 43 characters.
  CHALLENGE_FORMAT = /\A[A-Za-z0-9_-]{43}\z/
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1].freeze

  FIELDS.each { |field| attribute field, :string }

  validates :response_type, inclusion: { in: %w[code] }
  validates :code_challenge_method, inclusion: { in: %w[S256] }
  validates :code_challenge, format: { with: CHALLENGE_FORMAT }
  validates :state, presence: true, length: { maximum: 512 }
  validates :handle, length: { maximum: 40 }
  validates :name, length: { maximum: 120 }
  validates :app_name, length: { maximum: 80 }
  validate :redirect_uri_is_exact

  # Scalars only: an array or hash in a field fails validation as blank.
  def self.from(params)
    new(FIELDS.index_with { |field| params[field] }.select { |_, value| value.is_a?(String) })
  end

  # Kept in the session across sign-in, the same request comes back.
  def self.restore(value)
    return unless value.is_a?(Hash) && value["expires_at"].is_a?(Integer) && value["expires_at"] > Time.current.to_i

    request = from(value.fetch("request", {}).to_h.symbolize_keys)
    request if request.valid?
  end

  def to_session
    { "request" => to_h, "expires_at" => LIFETIME.from_now.to_i }
  end

  def to_h
    attributes.compact
  end

  def redirect_host
    redirect.host
  end

  # For CSP form-action: the browser checks a form's redirect target.
  def redirect_origin
    port = ":#{redirect.port}" unless redirect.port == redirect.default_port
    "#{redirect.scheme}://#{redirect.host}#{port}"
  end

  # The app's own query is kept (RFC 6749 §3.1.2); state always goes back.
  def callback_url(**values)
    uri = redirect.dup
    uri.query = URI.encode_www_form(URI.decode_www_form(uri.query.to_s) + values.merge(state: state).map { |key, value| [ key.to_s, value ] })
    uri.to_s
  end

  private

  def redirect
    @redirect ||= URI.parse(redirect_uri.to_s)
  end

  def redirect_uri_is_exact
    uri = redirect
    exact = redirect_uri.to_s.length <= 1024 && uri.is_a?(URI::HTTP) && uri.host.present? && uri.fragment.nil? && uri.userinfo.nil?
    secure = uri.scheme == "https" || (Rails.env.local? && LOOPBACK_HOSTS.include?(uri.host))
    errors.add(:redirect_uri, :invalid) unless exact && secure
  rescue URI::InvalidURIError
    errors.add(:redirect_uri, :invalid)
  end
end
