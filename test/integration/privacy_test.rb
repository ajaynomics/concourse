require "test_helper"
require "sentry/test_helper"

class PrivacyTest < ActionDispatch::IntegrationTest
  include Sentry::TestHelper
  test "message text never appears in logs or structured events" do
    User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    Agent.create!(owner: User.find_by!(handle: "ajay"), handle: "codex", oauth_client_id: "client-a")
    Agent.create!(owner: User.find_by!(handle: "riley"), handle: "pi", oauth_client_id: "client-b")
    secret = "privacy-token-#{SecureRandom.hex(12)}"

    capture_events do |events|
      with_memory_cache do
        stub_agent_token("token-a", client_id: "client-a", sub: "42", resource: :mcp)
        stub_agent_token("token-b", client_id: "client-b", sub: "7", resource: :mcp)
        logged = capture_log do
          A2a::Exchange.with_limits(inbox: 0.2) do
            sent = mcp_call("token-a", "send_message", { "to" => "riley/pi", "text" => secret })
            task_id = sent.dig("result", "structuredContent", "id")
            mcp_call("token-b", "next_task")
            mcp_call("token-b", "reply", {
              "task_id" => task_id,
              "text" => secret,
              "state" => "TASK_STATE_COMPLETED",
              "artifact_text" => secret
            })
            mcp_call("token-a", "get_task", { "id" => task_id })
          end
        end

        assert_not logged.include?(secret), logged
        assert events.none? { |event| event.inspect.include?(secret) }
      end
    end
  end

  test "event log routes never put message text in logs or structured events" do
    secret = "event-log-secret-#{SecureRandom.hex(12)}"
    previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    caller_user = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    recipient_user = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    sender = Agent.create!(owner: caller_user, handle: "codex", oauth_client_id: "client-a")
    recipient = Agent.create!(owner: recipient_user, handle: "pi", oauth_client_id: "client-b")
    stub_agent_token("token-a", client_id: "client-a", sub: "42")
    stub_agent_token("token-b", client_id: "client-b", sub: "7")
    bearer = ->(token) { { "Authorization" => "Bearer #{token}", "CONTENT_TYPE" => "application/json" } }
    responses = []

    capture_events do |events|
      logged = capture_log do
        task = Task.open!(caller: sender, recipient: recipient)
        Message.record!(task: task, role: "ROLE_USER", sender: sender, parts: [ { "text" => secret } ], metadata: { "note" => secret })
        A2a::Exchange.reply(agent: recipient, task_id: task.id, state: "TASK_STATE_COMPLETED", parts: [ { "text" => secret } ],
          artifacts: [ { "name" => secret, "parts" => [ { "text" => secret } ] } ])

        get api_events_path, params: { after: 0, limit: 10 }, headers: bearer.call("token-b")
        responses << response.body
        get api_events_path, params: { wait: 0 }, headers: bearer.call("token-a")
        responses << response.body
        A2a::Exchange.with_limits(stream: 0.1, heartbeat: 0.02, poll: 0.01) do
          get api_events_path, headers: bearer.call("token-b").merge("Accept" => "text/event-stream", "Last-Event-ID" => "0")
        end
        responses << response.body
        put api_events_cursor_path, params: { cursor: 1 }.to_json, headers: bearer.call("token-b")
        get api_me_path, headers: bearer.call("token-b")
        get api_events_path, params: { after: "not-a-cursor" }, headers: bearer.call("token-b")
        assert_response :bad_request
        get api_events_path, params: { after: 99 }, headers: bearer.call("token-b")
        assert_response :bad_request
        A2a::Waiters.limit = 0
        get api_events_path, params: { after: 1, wait: 1 }, headers: bearer.call("token-b")
        assert_response :too_many_requests
      end

      assert responses.all? { |body| body.include?(secret) }, "the routes do deliver content to the party it is for"
      assert_not logged.include?(secret), logged
      assert events.none? { |event| event.inspect.include?(secret) }
    end
  ensure
    A2a::Waiters.limit = nil
    A2a::Waiters.reset!
    Rails.application.config.x.concourse.release_line = previous_line
  end

  test "otel spans are not configured to record bodies or params" do
    names = Concourse::Telemetry::INSTRUMENTATIONS.keys
    assert_equal [
      "OpenTelemetry::Instrumentation::Rack",
      "OpenTelemetry::Instrumentation::ActionPack",
      "OpenTelemetry::Instrumentation::ActiveJob",
      "OpenTelemetry::Instrumentation::Net::HTTP"
    ], names
    assert names.none? { |name| name.include?("ActiveRecord") }

    Concourse::Telemetry::INSTRUMENTATIONS.each_value do |options|
      assert options.keys.none? { |key| key.to_s.match?(/body|param/) }, options.inspect
    end
    assert_equal [], Concourse::Telemetry::INSTRUMENTATIONS.dig("OpenTelemetry::Instrumentation::Rack", :allowed_request_headers)

    source = Rails.root.join("config/initializers/opentelemetry.rb").read
    assert_includes source, "Concourse::Telemetry::INSTRUMENTATIONS"
    assert_not source.match?(/Instrumentation::ActiveRecord/)
  end

  test "a sendmessage exception does not report message text to glitchtip" do
    secret = "glitchtip-secret-#{SecureRandom.hex(12)}"
    User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
    Agent.create!(owner: User.find_by!(handle: "ajay"), handle: "codex", oauth_client_id: "client-a")
    Agent.create!(owner: User.find_by!(handle: "riley"), handle: "pi", oauth_client_id: "client-b")

    Sentry.init do |config|
      config.dsn = Sentry::TestHelper::DUMMY_DSN
      config.breadcrumbs_logger = [ :active_support_logger ]
      config.rails.register_error_subscriber = true
      config.rails.report_rescued_exceptions = true
      Concourse::Glitchtip.apply(config)
    end
    setup_sentry_test

    with_memory_cache do
      stub_agent_token("token-a", client_id: "client-a", sub: "42")
      previous = A2a::Inbound.handler
      handler = Object.new
      handler.define_singleton_method(:blow) do |text|
        remembered = text
        raise "handler failed #{remembered.bytesize}"
      end
      A2a::Inbound.handler = ->(_task) { handler.blow(secret) }
      assert_raises(RuntimeError) do
        rpc(
          owner: "riley", agent: "pi", token: "token-a", method: "SendMessage",
          params: {
            "message" => {
              "role" => "ROLE_USER",
              "parts" => [ { "text" => secret } ],
              "messageId" => "glitch-1"
            },
            "configuration" => { "returnImmediately" => true }
          }
        )
      end
      A2a::Inbound.handler = previous
    end

    event = last_sentry_event
    assert event, "expected a Sentry event"
    serialized = JSON.generate(event.to_h)
    assert_not serialized.include?(secret), serialized
    assert_nil event.request&.data
    assert_includes serialized, "/a2a/concourse/riley/pi"
    assert_includes serialized, "SendMessage"
    assert_includes serialized, Agent.find_by!(handle: "codex").id.to_s
    assert_equal "ajay", event.user[:username]
    assert_equal "ajay@example.com", event.user[:email]
    assert_equal "ajay/codex", event.tags[:agent]
  ensure
    teardown_sentry_test
    Sentry::TestHelper.reset_sentry_globals!
  end

  # The one exception, by decision: Rybbit replay sees the owner pages as the
  # owner does, typed input included. Pinned so that a change either way is a
  # decision made in a diff, not a default that moved.
  test "rybbit replay records the owner pages unmasked, and only when a site is configured" do
    User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    sign_in_via_ajent
    assert_select "script[data-site-id]", count: 0

    analytics = Rails.application.config.x.analytics
    previous, analytics.site_id = analytics.site_id, "site-under-test"
    get root_path
    follow_redirect! while response.redirect?

    assert_select "script[data-site-id=site-under-test][src$='/api/script.js']" do |script|
      assert_equal "false", script.first["data-replay-mask-all-inputs"]
      assert_equal({ "password" => false, "email" => false }, JSON.parse(script.first["data-replay-mask-input-options"]))
    end
  ensure
    analytics.site_id = previous if analytics
  end

  private

  def capture_log
    previous = Rails.logger
    record = ActiveRecord::Base.logger
    buffer = StringIO.new
    logger = ActiveSupport::Logger.new(buffer)
    Rails.logger = logger
    ActiveRecord::Base.logger = logger
    yield
    buffer.string
  ensure
    Rails.logger = previous
    ActiveRecord::Base.logger = record
  end
end
