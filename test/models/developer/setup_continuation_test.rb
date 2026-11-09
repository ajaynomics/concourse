require "test_helper"

class Developer::SetupContinuationTest < ActiveSupport::TestCase
  STATE = "a" * 32

  test "start accepts only canonical ports and bounded URL-safe states" do
    [ "1024", "49152", "65535" ].each do |port|
      [ STATE, "_-" * 64 ].each do |state|
        setup = Developer::SetupContinuation.start(port: port, state: state)
        assert_equal port, setup.port
        assert_equal state, setup.state
        assert_equal 10.minutes.from_now.to_i, setup.expires_at
      end
    end
    [ nil, 49152, [ "49152" ], { "port" => "49152" }, "1023", "65536", "049152", "49152\n" ].each do |port|
      assert_nil Developer::SetupContinuation.start(port: port, state: STATE)
    end
    [ nil, [ STATE ], { "state" => STATE }, "a" * 31, "a" * 129, STATE + "=", STATE + "/", STATE + "\n" ].each do |state|
      assert_nil Developer::SetupContinuation.start(port: "49152", state: state)
    end
  end

  test "restore accepts only the vetted three-field hash with integer future expiry" do
    original = Developer::SetupContinuation.start(port: "49152", state: STATE).to_h
    assert_equal original, Developer::SetupContinuation.restore(original).to_h
    invalid = [
      nil, "not-a-hash", [], original.except("port"), original.merge("redirect_uri" => "https://evil.example"),
      original.merge("client_id" => "forged"), original.merge("port" => "65536"), original.merge("state" => "unsafe/state"),
      original.merge("expires_at" => original["expires_at"].to_s), original.merge("expires_at" => Time.current.to_i),
      original.merge("expires_at" => 11.minutes.from_now.to_i), original.symbolize_keys,
      original.merge(state: STATE), original.merge(1 => "unknown")
    ]
    invalid.each { |value| assert_nil Developer::SetupContinuation.restore(value), "must reject #{value.inspect}" }
  end

  test "restoring never renews the ten minute expiry" do
    original = Developer::SetupContinuation.start(port: "49152", state: STATE).to_h
    travel 9.minutes do
      assert_equal original, Developer::SetupContinuation.restore(original).to_h
    end
    travel 10.minutes do
      assert_nil Developer::SetupContinuation.restore(original)
    end
  end

  test "completion is a fixed loopback URL carrying only an encoded organization hint and state" do
    setup = Developer::SetupContinuation.start(port: "49152", state: "_-" * 16)
    organization = Organization.new(slug: "not-authority&owner=forged#fragment")
    uri = URI.parse(setup.completion_url(organization))
    assert_equal "http", uri.scheme
    assert_equal "127.0.0.1", uri.host
    assert_equal 49152, uri.port
    assert_equal "/setup-complete", uri.path
    assert_nil uri.userinfo
    assert_nil uri.fragment
    assert_equal [ [ "state", "_-" * 16 ], [ "organization", organization.slug ] ], URI.decode_www_form(uri.query)
  end
end
