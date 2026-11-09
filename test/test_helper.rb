ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"
require_relative "support/agent_tokens"

# Localhost is the test server. Everything else leaving the machine is a
# leaked call. Introspection tests stub the one call they make.
WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    # The suite uses :null_store so examples cannot leak through the cache.
    # Introspection is the one place a real cache is the behaviour under test.
    def with_memory_cache
      previous = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield Rails.cache
    ensure
      Rails.cache = previous
    end
  end
end

module OmniAuthTestHelper
  # Mirrors the provider's shape: the UserInfo payload lands in
  # extra.raw_info.
  def mock_ajent_auth(subject: "42", email: "ajay@example.com", name: "Ajay Krishnan", email_verified: true)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:ajent] = OmniAuth::AuthHash.new(
      provider: "ajent",
      uid: subject,
      info: { email: email, name: name, email_verified: email_verified },
      extra: {
        raw_info: {
          "iss" => Rails.application.config.x.oidc.issuer,
          "sub" => subject,
          "email" => email,
          "email_verified" => email_verified,
          "name" => name
        }
      }
    )
  end

  # Organization creation is a deployment setting; a test that needs it open
  # opens it for its own duration.
  def with_organization_creation(setting)
    previous = Rails.application.config.x.concourse.organization_creation
    Rails.application.config.x.concourse.organization_creation = setting
    yield
  ensure
    Rails.application.config.x.concourse.organization_creation = previous
  end

  def sign_in_via_ajent(**options)
    mock_ajent_auth(**options)
    get "/auth/ajent/callback"
    follow_redirect! while response.redirect?
  end
end

class ActionDispatch::IntegrationTest
  include OmniAuthTestHelper
  include AgentTokens
  include EventCapture
end

class ActiveSupport::TestCase
  include EventCapture
  include OmniAuthTestHelper
  include AgentTokens
end
