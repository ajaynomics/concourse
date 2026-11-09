require "test_helper"

# Every destination reaches Falcon through a Cloudflare Tunnel. Cloudflare's
# edge writes the visitor into X-Forwarded-For; cloudflared and kamal-proxy
# then relay it from inside the host, hops Rails trusts by default. So the app
# trusts nothing more, and Cloudflare's published ranges least of all: they
# also carry other customers' Workers, which write their own X-Forwarded-For.
class TrustedProxiesTest < ActiveSupport::TestCase
  test "a request through the tunnel reports the visitor" do
    assert_equal "198.51.100.7", remote_ip("198.51.100.7")
  end

  test "a Worker on Cloudflare reports its own address, not the one it wrote" do
    assert_equal "162.158.0.1", remote_ip("203.0.113.9, 162.158.0.1")
  end

  test "Rails' defaults are the only trusted proxies" do
    assert_nil Rails.application.config.action_dispatch.trusted_proxies,
      "behind the tunnel no extra proxy is needed, and Cloudflare's ranges are unsafe"
  end

  private
    # kamal-proxy reaches Falcon over the Docker bridge, having appended its
    # own peer, cloudflared, to the edge's X-Forwarded-For.
    def remote_ip(forwarded_for)
      app = ->(env) { [ 200, {}, [ ActionDispatch::Request.new(env).remote_ip ] ] }
      stack = ActionDispatch::RemoteIp.new(app, true, Rails.application.config.action_dispatch.trusted_proxies)

      Rack::MockRequest.new(stack).get("/", "REMOTE_ADDR" => "172.18.0.5",
        "HTTP_X_FORWARDED_FOR" => "#{forwarded_for}, 172.18.0.1").body
    end
end
