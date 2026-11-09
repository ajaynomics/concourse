require "test_helper"

class PushSubscriptionTest < ActiveSupport::TestCase
  setup { @user = User.create!(ajent_sub: "42", handle: "ajay", organizations: [ Organization.default ]) }

  test "only a browser push service is accepted as an endpoint" do
    %w[
      https://fcm.googleapis.com/fcm/send/abc
      https://jmt17.google.com/fcm/send/abc
      https://updates.push.services.mozilla.com/wpush/v2/abc
      https://web.push.apple.com/abc
      https://wns2-bl2p.notify.windows.com/w/?token=abc
    ].each do |endpoint|
      assert PushSubscription.new(user: @user, endpoint: endpoint, p256dh_key: "p", auth_key: "a").valid?, endpoint
    end

    %w[
      http://fcm.googleapis.com/fcm/send/abc
      https://169.254.169.254/latest
      https://fcm.googleapis.com.evil.example/x
      https://google.com.evil.example/x
      https://script.google.com/macros/s/abc/exec
      https://localhost:3000/push
    ].each do |endpoint|
      assert_not PushSubscription.new(user: @user, endpoint: endpoint, p256dh_key: "p", auth_key: "a").valid?, endpoint
    end
  end

  # The browser's side of RFC 8291, done here with a key pair of our own, so
  # what is posted is proven to decrypt and to carry a VAPID token (RFC 8292)
  # the push service will accept.
  test "a delivered alert decrypts with the browser's keys and carries a valid VAPID token" do
    browser = OpenSSL::PKey::EC.generate("prime256v1")
    auth = SecureRandom.random_bytes(16)
    subscription = PushSubscription.create!(user: @user, endpoint: "https://fcm.googleapis.com/fcm/send/abc",
      p256dh_key: b64(raw_public(browser)), auth_key: b64(auth))
    vapid = WebPush.generate_key
    posted = nil
    stub_request(:post, subscription.endpoint).to_return { |request| posted = request; { status: 201 } }

    with_vapid(vapid) { assert subscription.deliver(title: "riley/pi sent ajay/codex a task", path: "/tasks/1") }

    assert_equal "aes128gcm", posted.headers["Content-Encoding"]
    assert_equal "high", posted.headers["Urgency"]
    assert_equal({ "title" => "riley/pi sent ajay/codex a task", "path" => "/tasks/1" },
      JSON.parse(decrypt(posted.body.b, browser, auth)))

    token, key = posted.headers["Authorization"].match(/\Avapid t=([^,]+),\s*k=(.+)\z/).captures
    assert_equal vapid.public_key.delete("="), key.delete("=")
    claims, = JWT.decode(token, public_key(Base64.urlsafe_decode64(key)), true, algorithm: "ES256")
    assert_equal "https://fcm.googleapis.com", claims["aud"]
    assert_match(/\Amailto:/, claims["sub"])
    assert claims["exp"] > Time.now.to_i
  end

  test "a subscription the push service says is gone is deleted" do
    subscription = PushSubscription.create!(user: @user, endpoint: "https://fcm.googleapis.com/fcm/send/gone",
      p256dh_key: b64(raw_public(OpenSSL::PKey::EC.generate("prime256v1"))), auth_key: b64(SecureRandom.random_bytes(16)))
    stub_request(:post, subscription.endpoint).to_return(status: 410)

    with_vapid(WebPush.generate_key) { assert_not subscription.deliver(title: "x") }
    assert_not PushSubscription.exists?(subscription.id)
  end

  private

  def with_vapid(key)
    previous = Rails.application.config.x.vapid
    Rails.application.config.x.vapid = { subject: "mailto:ajay@krishnan.ca", public_key: key.public_key, private_key: key.private_key }
    yield
  ensure
    Rails.application.config.x.vapid = previous
  end

  def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

  def raw_public(key) = key.public_key.to_bn.to_s(2)

  def public_key(raw)
    OpenSSL::PKey::EC.new(OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::ObjectId("id-ecPublicKey"), OpenSSL::ASN1::ObjectId("prime256v1") ]),
      OpenSSL::ASN1::BitString(raw)
    ]).to_der)
  end

  def hmac(key, data) = OpenSSL::HMAC.digest("SHA256", key, data)

  # RFC 8188 header (salt, record size, key id = the server's public key),
  # then RFC 8291's key schedule.
  def decrypt(body, browser, auth)
    salt, id_length = body[0, 16], body[20].ord
    server_public = body[21, id_length]
    ciphertext = body[(21 + id_length)..]

    ikm = hmac(hmac(auth, browser.derive(public_key(server_public))),
      "WebPush: info\0" + raw_public(browser) + server_public + "\x01")
    prk = hmac(salt, ikm)
    cipher = OpenSSL::Cipher.new("aes-128-gcm").decrypt
    cipher.key = hmac(prk, "Content-Encoding: aes128gcm\0\x01")[0, 16]
    cipher.iv = hmac(prk, "Content-Encoding: nonce\0\x01")[0, 12]
    cipher.auth_tag = ciphertext[-16..]
    plain = cipher.update(ciphertext[0...-16]) + cipher.final
    plain.sub(/\x02\x00*\z/n, "")
  end
end
