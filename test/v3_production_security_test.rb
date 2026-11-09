# The subprocess boots the real production middleware stack, never a server.
if ENV["V3_SECURITY_FIXTURE"] == "1"
  require "bundler/setup"
  require "webmock"
  WebMock.enable!
  WebMock.disable_net_connect!
  require "rails"
  require "active_support/combined_configuration"
  require "active_support/encrypted_configuration"
  require "sentry-ruby"
  Sentry.singleton_class.prepend(Module.new do
    def init(&block)
      super do |config|
        block.call(config)
        config.transport.transport_class = Sentry::DummyTransport
      end
    end
  end)

  # No ambient ENV/credential fallback, even for optional services.
  ActiveSupport::CombinedConfiguration.prepend(Module.new do
    def option(*keys, default: nil)
      settings = {
        app: { url: "https://canonical.example.test" },
        concourse: { default_organization: "fixture", organization_creation: "closed" },
        oidc: { issuer: "https://issuer.example.test", client_id: "synthetic-web", client_secret: "synthetic-secret" },
        introspection: { client_id: "synthetic-introspection", client_secret: "synthetic-secret" },
        glitchtip: { dsn: "https://public@errors.example.test/1" },
        rybbit: { host: "https://analytics.example.test" },
        vapid: {}, relay: { enabled: false, outbound_enabled: false }
      }
      settings.dig(*keys)
    end
  end)
  ActiveSupport::EncryptedConfiguration.prepend(Module.new do
    def read
      raise "Production security fixture must not read encrypted credentials"
    end
  end)

  require_relative "../config/application"
  directory = ENV.fetch("FIXTURE_DIRECTORY")
  Rails.application.config.define_singleton_method(:database_configuration) do
    { "production" => %w[primary cache queue cable].to_h { |role|
      [ role, { "adapter" => "sqlite3", "database" => File.join(directory, "#{role}.sqlite3") } ]
    } }
  end
  require_relative "../config/environment"
  ActiveRecord::Schema.verbose = false
  load Rails.root.join("db/schema.rb")

  checks = 0
  check = ->(condition, label) do
    raise "Production security check failed: #{label}" unless condition
    checks += 1
  end
  app = Rails.application
  v3 = ENV.fetch("FIXTURE_RELEASE") == "3"
  check.call(app.config.assume_ssl == v3, "release-specific assume_ssl")
  check.call(app.config.force_ssl == v3, "release-specific force_ssl")
  check.call(app.config.hosts == (v3 ? [ "canonical.example.test" ] : []), "exact host allowlist")
  check.call(app.config.session_options[:secure] == (v3 ? true : nil), "session secure default")
  check.call(!Agent.native_relay_complete?, "native relay stays unavailable")

  # Rack::MockRequest sets SERVER_NAME but omits the real HTTP Host header.
  rack = Class.new(Rack::MockRequest) do
    def request(method, uri, options = {})
      super(method, uri, { "HTTP_HOST" => URI(uri).host }.merge(options))
    end
  end.new(app)
  canonical = "http://canonical.example.test"
  health = rack.get("http://127.0.0.1/up")
  check.call(health.status == 200 && !health.headers.key?("location"), "internal plain HTTP health")
  check.call(rack.head("http://127.0.0.1/up").status == 200, "internal HEAD health")
  check.call(rack.get("http://127.0.0.1/up?probe=1").status == 200, "health query compatibility")
  check.call(rack.post("http://127.0.0.1/up").status == 403, "health exception read methods only") if v3
  [ "/up/", "/up/anything", "/api/identity", "/.well-known/oauth-protected-resource" ].each do |path|
    response = rack.get("http://untrusted.example.test#{path}")
    check.call(response.status == 403, "health exception does not cover #{path}") if v3
  end

  metadata = rack.get("#{canonical}/.well-known/oauth-protected-resource")
  check.call(metadata.status == 200, "canonical resource response")
  check.call(JSON.parse(metadata.body).fetch("resource") == "https://canonical.example.test", "canonical resource origin")
  unauthorized = rack.get("#{canonical}/api/identity", "HTTP_X_FORWARDED_PROTO" => "http")
  check.call(unauthorized.status == 401, "proxy plaintext does not redirect bearer requests")
  check.call(unauthorized.headers.fetch("www-authenticate").include?('resource_metadata="https://canonical.example.test/.well-known/oauth-protected-resource"'), "canonical bearer challenge")
  check.call(unauthorized.headers.key?("strict-transport-security") == v3, "HSTS only in v3")

  cookie_response = rack.get("#{canonical}/auth/failure")
  check.call(cookie_response.status == 302, "cookie-producing session response")
  cookies = Array(cookie_response.headers.fetch("set-cookie"))
  session_cookie = cookies.find { |cookie| cookie.start_with?("_concourse_session=") }
  check.call(!session_cookie.nil?, "real session cookie present")
  check.call(/;\s*secure(?:;|$)/i.match?(session_cookie) == v3, "actual secure session cookie")
  check.call(cookies.all? { |cookie| /;\s*secure(?:;|$)/i.match?(cookie) }, "all cookies secure") if v3
  check.call(cookie_response.headers.fetch("location").start_with?(v3 ? "https://canonical.example.test/" : "http://canonical.example.test/"), "request-derived redirect scheme")

  sitemap = rack.get("#{canonical}/sitemap.xml")
  check.call(sitemap.status == 200 && sitemap.body.include?("https://canonical.example.test/join"), "canonical sitemap URLs")
  if v3
    [ "untrusted.example.test", "sub.canonical.example.test", "canonical.example.test.evil.test" ].each do |host|
      check.call(rack.get("http://#{host}/api/identity").status == 403, "reject noncanonical host")
    end
    check.call(rack.get("#{canonical}/api/identity", "HTTP_X_FORWARDED_HOST" => "untrusted.example.test").status == 403, "reject spoofed forwarded host")
    check.call(rack.get("http://untrusted.example.test/api/identity", "HTTP_X_FORWARDED_HOST" => "canonical.example.test").status == 403, "forwarded host cannot rescue hostile host")
  else
    check.call(app.config.ssl_options == { hsts: { subdomains: true } } && app.config.host_authorization == {}, "legacy options unchanged")
    check.call(rack.get("http://untrusted.example.test/api/identity").status == 401, "legacy host behavior unchanged")
  end
  check.call(WebMock::RequestRegistry.instance.requested_signatures.hash.empty?, "zero outbound HTTP")
  puts "PRODUCTION_SECURITY_OK release=#{ENV.fetch('FIXTURE_RELEASE')} checks=#{checks}"
else
  require "test_helper"
  require "tmpdir"
  require "timeout"
  require "rbconfig"

  class V3ProductionSecurityTest < ActiveSupport::TestCase
    test "v3 real production boot enforces canonical host and secure cookies with internal health" do
      assert_production_security(3)
    end

    test "release one real production boot retains legacy TLS and host behavior" do
      assert_production_security(1)
    end

    private

    def assert_production_security(release)
      Dir.mktmpdir("v3-production-security-") do |directory|
        env = {
          "PATH" => "#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin", "HOME" => directory,
          "CI" => "true", "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "synthetic-" + "a" * 128,
          "RAILS_LOG_LEVEL" => "fatal", "V3_SECURITY_FIXTURE" => "1",
          "FIXTURE_RELEASE" => release.to_s, "FIXTURE_DIRECTORY" => directory,
          "CONCOURSE__RELEASE_LINE" => release.to_s,
          "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s
        }
        output = File.join(directory, "receipt.log")
        pid = Process.spawn(env, RbConfig.ruby, __FILE__, chdir: Rails.root.to_s,
          unsetenv_others: true, out: output, err: output)
        status = nil
        begin
          _, status = Timeout.timeout(45) { Process.waitpid2(pid) }
          assert status.success?, File.read(output)
          receipt = File.read(output)[/PRODUCTION_SECURITY_OK release=#{release} checks=\d+/]
          assert_not_nil receipt
          puts receipt
        ensure
          unless status
            Process.kill("TERM", pid)
            Process.waitpid(pid)
          end
        end
      end
    end
  end
end
