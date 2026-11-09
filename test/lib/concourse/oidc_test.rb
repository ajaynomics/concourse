require "test_helper"

# The provider options are the whole security posture of sign-in, and they are
# invisible to every other test: OmniAuth.config.test_mode bypasses the
# strategy, so dropping pkce, flipping response_type or unsetting uid_field
# would leave the suite green. This pins them directly.
class Concourse::OidcTest < ActiveSupport::TestCase
  def options = Concourse::Oidc.provider_options

  test "the provider is discovery-based so endpoints are never hardcoded" do
    assert_equal true, options[:discovery]
  end

  test "PKCE is on and the exchange is authorization code" do
    assert_equal true, options[:pkce]
    assert_equal :code, options[:response_type]
  end

  test "the signing algorithm is pinned so the token cannot choose it" do
    assert_equal :RS256, options[:client_signing_alg]
  end

  test "identity is keyed on sub, never email" do
    assert_equal "sub", options[:uid_field]
  end

  test "email and profile are requested for email_verified and the name" do
    assert_equal %i[openid email profile], options[:scope]
  end

  test "the provider is named ajent, which the callback route depends on" do
    assert_equal :ajent, options[:name]
  end

  test "configured? is false when a credential is missing" do
    config = ActiveSupport::OrderedOptions.new
    config.issuer = "http://www.example.com"
    config.client_id = "id"
    config.client_secret = nil

    assert_not Concourse::Oidc.configured?(config)

    config.client_secret = "secret"
    assert Concourse::Oidc.configured?(config)
  end
end
