require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Concourse
  # Safe reader for config.x.
  #
  # config.x's method_missing returns a truthy-but-empty OrderedOptions for
  # unset keys, which is easy to mistake for a real value. This collapses
  # nil / "" / {} / [] / empty OrderedOptions to nil. false and 0 pass
  # through unchanged.
  def self.config(*path)
    raise ArgumentError, "config path required" if path.empty?

    value = Rails.application.config.x.public_send(path.first)
    path.drop(1).each do |key|
      return unless value.respond_to?(:dig)
      value = value.dig(key)
    end

    value unless value.respond_to?(:empty?) && value.empty?
  end

  # The deployed revision, for telemetry and error reports.
  #
  # Kamal sets KAMAL_VERSION on every container it runs. REVISION is only a
  # builder arg unless the Dockerfile promotes it, so reading REVISION alone
  # silently yields nil in production.
  def self.revision
    ENV["KAMAL_VERSION"].presence || ENV["REVISION"].presence
  end

  def self.app_url
    config(:app, :url).to_s.chomp("/")
  end

  def self.v3?
    config(:concourse, :release_line).to_i == 3
  end

  def self.authorization_server
    config(:oidc, :issuer).to_s.chomp("/")
  end

  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.2

    # Select before config_for reads credentials; no implicit cross-environment fallback.
    if ENV["CONCOURSE__RELEASE_LINE"].to_i == 3
      config.credentials.content_path = config.root.join("config/credentials/v3.yml.enc")
      config.credentials.key_path = config.root.join("config/credentials/v3.key")
    end

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib_once(ignore: %w[assets tasks])

    # One thread in each of Action Cable's pools, so broadcasts reach the
    # browser in the order they were sent. Only socket work runs there; HTTP
    # stays on Falcon's fibers.
    config.action_cable.worker_pool_size = 1
    config.action_cable.executor_pool_size = 1

    # Every service's configuration, read once here rather than in one-line
    # initializers. The application body runs before all of them, which is
    # what a content security policy needs when it resolves the issuer while
    # the policy compiles.
    #
    # config/environments/*.rb still loads after this, so an environment may
    # override any of it.
    config.x.ajent = config_for(:ajent)
    config.x.analytics = config_for(:analytics)
    config.x.vapid = config_for(:vapid)
    config.x.smtp = config_for(:smtp)
    config.x.app = config_for(:app)
    config.x.concourse = config_for(:concourse)
    config.x.glitchtip = config_for(:glitchtip)
    config.x.introspection = config_for(:introspection)
    config.x.oidc = config_for(:oidc)
    config.x.relay = config_for(:relay)
  end
end
