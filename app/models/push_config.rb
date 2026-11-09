# An agent's own webhook. When an event lands in the agent's log, Concourse
# POSTs a content-free notice there; the agent then reads the event itself
# from /api/events. This is a Concourse extension, not A2A per-task push
# (§4.3), which the JSON-RPC methods and the card still refuse; it follows the
# webhook caller rules of A2A §13.2: token in a header, timeouts, backoff,
# no private destinations.
class PushConfig < ApplicationRecord
  TIMEOUT = 5
  # Visible ASCII: no spaces or control characters, so it survives a header.
  TOKEN_FORMAT = /\A[\x21-\x7E]{16,256}\z/
  NETWORK_ERRORS = [ Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError ].freeze

  # Worth trying again: the receiver was down, busy or unreachable.
  class Undelivered < StandardError; end
  # Will not get better by retrying: a 3xx/4xx answer, or a URL that is no longer public.
  class Refused < StandardError; end

  belongs_to :agent
  encrypts :token

  validates :agent_id, uniqueness: true
  validates :url, presence: true, length: { maximum: 2048 }
  validates :token, format: { with: TOKEN_FORMAT }
  validate :public_https_url

  def self.addresses(host)
    Addrinfo.getaddrinfo(host, 443, nil, :STREAM).map(&:ip_address).uniq
  end

  # True on any 2xx. Redirects are not followed, and the body is never read.
  def deliver(event)
    uri, address = public_destination
    raise Refused, "url is not public" unless uri

    status = post(uri, address, event)
    return true if status.between?(200, 299)
    raise Undelivered, "status #{status}" if status == 429 || status >= 500

    raise Refused, "status #{status}"
  end

  # Outcomes skip validation and updated_at: saving would resolve the host
  # again, and updated_at tells the agent when it last changed its config.
  def delivered!
    update_columns(last_succeeded_at: Time.current, consecutive_failures: 0)
  end

  def undelivered!
    increment!(:consecutive_failures)
    update_columns(last_failed_at: Time.current)
  end

  # Failing: the most recent notice Concourse gave up on came after the last success.
  def failing?
    consecutive_failures.positive?
  end

  def as_json(*)
    { "url" => url, "updated_at" => updated_at.utc.iso8601(3) }
  end

  private

  # References only. The receiver reads content from /api/events.
  def notice(event)
    { agent: agent.qualified_handle, event_id: event.seq, task_id: event.task_id, kind: event.kind }
  end

  def post(uri, address, event)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["X-A2A-Notification-Token"] = token
    request["Concourse-Event-Id"] = event.seq.to_s
    request.body = notice(event).to_json
    # No proxy, and the socket goes to the address just checked rather than
    # whatever the name resolves to next (DNS rebinding). TLS still sends and
    # verifies the hostname.
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.ipaddr = address
    http.use_ssl = true
    http.open_timeout = http.read_timeout = http.write_timeout = TIMEOUT
    http.max_retries = 0
    http.start do |connection|
      # Returning from the block closes the connection before the body is read.
      connection.request(request) { |response| return response.code.to_i }
    end
  end

  # The URI and an address to connect to, or nil unless the URL is HTTPS and
  # every address its host has is public. Checked on save and again before
  # each send; DNS may have changed.
  def public_destination
    uri = A2a::NativeTransport.https_uri(url)
    addresses = self.class.addresses(uri.host)
    [ uri, addresses.first ] if addresses.any? && addresses.all? { |address| public_address?(address) }
  rescue A2a::NativeTransport::ConfigurationError
    nil
  end

  def public_address?(address)
    A2a::NativeTransport.public_address(address)
  rescue A2a::NativeTransport::ConfigurationError
    false
  end

  def public_https_url
    return if url.blank? || errors.include?(:url)

    errors.add(:url, "must be a public HTTPS URL") unless public_destination
  rescue SocketError
    errors.add(:url, "does not resolve")
  end
end
