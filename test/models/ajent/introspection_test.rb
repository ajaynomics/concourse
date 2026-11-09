require "test_helper"

class Ajent::IntrospectionTest < ActiveSupport::TestCase
  INTROSPECT = "http://www.example.com/oauth/introspect"
  APP = "https://concourse.example.com"

  setup do
    @token = "access-token-1"
    @payload = {
      "active" => true,
      "scope" => "openid concourse",
      "client_id" => "client-1",
      "sub" => "42",
      "aud" => APP,
      "exp" => 30.minutes.from_now.to_i
    }
  end

  test "accepts an active token whose audience is the app and whose scope includes concourse" do
    with_memory_cache do
      stub_introspection(@payload)

      payload = Ajent::Introspection.authenticate(@token, audience: APP)

      assert_equal "42", payload["sub"]
      assert_requested :post, INTROSPECT, times: 1 do |request|
        request.headers["Authorization"] == "Basic #{Base64.strict_encode64("concourse-introspection:test_introspection_secret")}"
      end
    end
  end

  test "accepts an audience only when the expected resource is present exactly" do
    with_memory_cache do
      stub_introspection(@payload.merge("aud" => "#{APP}/mcp"))
      assert Ajent::Introspection.authenticate("mcp-token", audience: "#{APP}/mcp")["active"]

      stub_introspection(@payload.merge("aud" => [ "https://other.example", APP ]))
      assert Ajent::Introspection.authenticate("array-token", audience: APP)["active"]

      [
        [ "#{APP}/mcp", APP ],
        [ "#{APP}/", APP ],
        [ [ "https://other.example", "#{APP}/" ], APP ],
        [ APP, "#{APP}/mcp" ]
      ].each_with_index do |(aud, audience), index|
        stub_introspection(@payload.merge("aud" => aud))
        assert_raises(Ajent::Introspection::Rejected) do
          Ajent::Introspection.authenticate("reject-#{index}", audience: audience)
        end
      end
    end
  end

  test "rejects a token that is inactive, misscoped, addressed elsewhere, or subject-less" do
    with_memory_cache do
      [
        @payload.merge("active" => false),
        @payload.merge("scope" => "openid"),
        @payload.merge("aud" => "https://example.test"),
        @payload.merge("sub" => nil),
        @payload.merge("sub" => ""),
        @payload.merge("sub" => "   "),
        @payload.except("sub"),
        @payload.merge("exp" => 1.minute.ago.to_i)
      ].each_with_index do |payload, index|
        stub_introspection(payload)
        assert_raises(Ajent::Introspection::Rejected) do
          Ajent::Introspection.authenticate("#{@token}-#{index}", audience: APP)
        end
      end
    end
  end

  test "an inactive answer is cached by digest for a minute, so a repeated bad token does not reach Ajent" do
    with_memory_cache do |cache|
      stub_introspection({ "active" => false })

      assert_raises(Ajent::Introspection::Inactive) do
        Ajent::Introspection.authenticate(@token, audience: APP)
      end
      # The cached answer is still a rejection, but not a fresh one.
      error = assert_raises(Ajent::Introspection::Rejected) do
        Ajent::Introspection.authenticate(@token, audience: APP)
      end
      assert_not_kind_of Ajent::Introspection::Inactive, error
      assert_requested :post, INTROSPECT, times: 1
      assert cache.exist?("ajent/introspection/#{Digest::SHA256.hexdigest(@token)}")
      assert_not cache.exist?("ajent/introspection/#{@token}")

      travel 61.seconds do
        assert_raises(Ajent::Introspection::Rejected) do
          Ajent::Introspection.authenticate(@token, audience: APP)
        end
      end
      assert_requested :post, INTROSPECT, times: 2
    end
  end

  test "an active token refused locally is not cached, so it passes once the local cause is fixed" do
    with_memory_cache do
      stub_introspection(@payload.merge("scope" => "openid"))
      assert_raises(Ajent::Introspection::Rejected) do
        Ajent::Introspection.authenticate(@token, audience: APP)
      end

      stub_introspection(@payload)
      assert Ajent::Introspection.authenticate(@token, audience: APP)["active"]
    end
  end

  test "an answer that is neither active nor inactive is refused but neither cached nor counted" do
    with_memory_cache do
      [ {}, { "active" => "false" }, [] ].each do |answer|
        stub_introspection(answer)
        error = assert_raises(Ajent::Introspection::Rejected) do
          Ajent::Introspection.authenticate(@token, audience: APP)
        end
        assert_not_kind_of Ajent::Introspection::Inactive, error
      end

      stub_introspection(@payload)
      assert Ajent::Introspection.authenticate(@token, audience: APP)["active"]
    end
  end

  test "an outage is never cached as a rejection" do
    with_memory_cache do
      stub_request(:post, INTROSPECT).to_return(status: 503)
      assert_raises(Ajent::Introspection::Unavailable) do
        Ajent::Introspection.authenticate(@token, audience: APP)
      end

      stub_introspection(@payload)
      assert Ajent::Introspection.authenticate(@token, audience: APP)["active"]
    end
  end

  test "caches by token digest for at most ten minutes and does not store the token" do
    with_memory_cache do |cache|
      stub_introspection(@payload)
      Ajent::Introspection.authenticate(@token, audience: APP)
      Ajent::Introspection.authenticate(@token, audience: APP)

      assert_requested :post, INTROSPECT, times: 1
      digest = Digest::SHA256.hexdigest(@token)
      assert cache.exist?("ajent/introspection/#{digest}")
      assert_not cache.exist?("ajent/introspection/#{@token}")
    end
  end

  test "a cached answer survives Ajent being unreachable until it expires" do
    with_memory_cache do
      stub_introspection(@payload.merge("exp" => 2.minutes.from_now.to_i))
      Ajent::Introspection.authenticate(@token, audience: APP)

      stub_request(:post, INTROSPECT).to_timeout
      assert Ajent::Introspection.authenticate(@token, audience: APP)["active"]

      travel 3.minutes do
        assert_raises(Ajent::Introspection::Unavailable) do
          Ajent::Introspection.authenticate(@token, audience: APP)
        end
      end
    end
  end

  test "an unreachable Ajent with nothing cached fails closed" do
    with_memory_cache do
      stub_request(:post, INTROSPECT).to_timeout

      assert_raises(Ajent::Introspection::Unavailable) do
        Ajent::Introspection.authenticate(@token, audience: APP)
      end
    end
  end

  private

  def stub_introspection(payload)
    stub_request(:post, INTROSPECT).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: payload.to_json
    )
  end
end
