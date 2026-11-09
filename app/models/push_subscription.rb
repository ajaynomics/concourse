# A browser's Web Push subscription (RFC 8030, keys per RFC 8291) for one
# user. This is Web Push to people, not A2A push notifications, which
# Concourse still does not support (§3.3.4).
class PushSubscription < ApplicationRecord
  # The push services the major browsers use. The endpoint arrives from the
  # browser, and Concourse posts to it; an allow-list keeps that post from
  # being pointed at anything else.
  PUSH_HOSTS = [
    /\Afcm\.googleapis\.com\z/,
    /\Ajmt\d+\.google\.com\z/, # Chromium builds get jmt17.google.com/fcm/send/...
    /\Aupdates\.push\.services\.mozilla\.com\z/,
    /\A[a-z0-9.-]+\.push\.apple\.com\z/,
    /\A[a-z0-9.-]+\.notify\.windows\.com\z/
  ].freeze

  TIMEOUT = 5

  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh_key, :auth_key, presence: true
  validate :endpoint_is_a_push_service

  def self.configured?
    vapid[:public_key].present? && vapid[:private_key].present?
  end

  def self.public_key
    vapid[:public_key]
  end

  def self.vapid
    Rails.application.config.x.vapid.to_h.symbolize_keys
  end

  # The payload is encrypted to the browser, and still carries no message or
  # artifact content: handles, a state, and a path on Concourse.
  def deliver(payload)
    WebPush.payload_send(
      message: payload.to_json,
      endpoint: endpoint,
      p256dh: p256dh_key,
      auth: auth_key,
      vapid: self.class.vapid.slice(:subject, :public_key, :private_key),
      ttl: 1.hour.to_i,
      urgency: "high",
      # One slow push service must not hold up alerts for everyone else.
      open_timeout: TIMEOUT, read_timeout: TIMEOUT, ssl_timeout: TIMEOUT
    )
    true
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
    destroy
    false
  rescue WebPush::ResponseError, Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError => error
    Rails.error.report(error, handled: true, context: { push_subscription_id: id })
    false
  end

  private

  def endpoint_is_a_push_service
    uri = URI.parse(endpoint.to_s)
    return if uri.is_a?(URI::HTTPS) && PUSH_HOSTS.any? { |host| host.match?(uri.host.to_s) }

    errors.add(:endpoint, "is not a known push service")
  rescue URI::InvalidURIError
    errors.add(:endpoint, "is not a URL")
  end
end
