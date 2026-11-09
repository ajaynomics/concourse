require "test_helper"

class StuckMailAlertJobTest < ActiveJob::TestCase
  setup do
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @previous_vapid = Rails.application.config.x.vapid
    key = WebPush.generate_key
    Rails.application.config.x.vapid = { subject: "mailto:test@example.com", public_key: key.public_key, private_key: key.private_key }

    @organization = Organization.create!(name: "Dana", slug: "dana-test")
    @owner = User.create!(handle: "dana", ajent_sub: "stuck-owner")
    @organization.memberships.create!(user: @owner, role: "owner")
    @member = User.create!(handle: "peer", ajent_sub: "stuck-member", organizations: [ @organization ])
    @owner.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/owner", p256dh_key: "p", auth_key: "a")
    @member.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/member", p256dh_key: "p", auth_key: "a")
    @assistant = Agent.create!(owner: @owner, organization: @organization, handle: "sam-lee", oauth_client_id: "client-a")
    @peer = Agent.create!(owner: @member, organization: @organization, handle: "pi", oauth_client_id: "client-b")
  end

  teardown do
    Rails.application.config.x.vapid = @previous_vapid
    Rails.application.config.x.concourse.release_line = @previous_line
  end

  test "alerts the owners once per stuck episode, and again after recovery" do
    task = send_task(@peer, @assistant, "secret-sentinel")

    travel 30.minutes
    assert_empty sweep, "the 15-minute band never alerts: the agent may be asking a person"

    travel 31.minutes
    payloads = sweep
    assert_equal 1, payloads.size, "owners only, not every member"
    assert_equal "Mail is stuck for dana/sam-lee", payloads.sole[:title]
    assert_equal "/dana-test/health", payloads.sole[:path]
    assert_not_includes payloads.to_json, "secret-sentinel"
    assert @assistant.reload.stuck_alerted_at

    travel 10.minutes
    assert_empty sweep, "still the same episode"

    task.transition_to!("TASK_STATE_COMPLETED", by: @assistant)
    assert_empty sweep
    assert_nil @assistant.reload.stuck_alerted_at

    send_task(@peer, @assistant, "again")
    travel 61.minutes
    assert_equal 1, sweep.size, "a new episode alerts again"
  end

  test "a long WORKING task never alerts, and never holds back a later alert" do
    rollout = send_task(@peer, @assistant, "roll this out")
    rollout.transition_to!("TASK_STATE_WORKING", by: @assistant)
    Message.record!(task: rollout, role: "ROLE_AGENT", sender: @assistant, parts: [ { "text" => "On it; waiting on a browser step." } ])

    travel 3.days
    assert_empty sweep
    assert_nil @assistant.reload.stuck_alerted_at

    send_task(@peer, @assistant, "a new question")
    travel 61.minutes
    assert_equal 1, sweep.size
  end

  test "a stalled event feed alerts" do
    task = Task.open!(caller: @peer, recipient: @assistant)
    Message.record!(task: task, role: "ROLE_USER", sender: @peer, parts: [ { "text" => "first" } ])
    AgentEvent.acknowledge!(@assistant, 1)
    task.transition_to!("TASK_STATE_COMPLETED", by: @assistant)
    Task.open!(caller: @peer, recipient: @assistant).then do |other|
      Message.record!(task: other, role: "ROLE_USER", sender: @peer, parts: [ { "text" => "second" } ])
      other.transition_to!("TASK_STATE_COMPLETED", by: @assistant)
    end

    travel 61.minutes
    assert_equal 0, @organization.mail_health.rows.find { |row| row.agent == @assistant }.stuck, "nothing unanswered, only unread"
    assert_equal 1, sweep.size
  end

  test "names every agent newly stuck in one alert" do
    send_task(@peer, @assistant, "one")
    send_task(@assistant, @peer, "two")

    travel 61.minutes
    payload = sweep.sole
    assert_equal "Mail is stuck for 2 agents", payload[:title]
    assert_includes payload[:body], "dana/sam-lee"
    assert_includes payload[:body], "peer/pi"
  end

  test "does nothing without VAPID keys" do
    Rails.application.config.x.vapid = {}
    send_task(@peer, @assistant, "hello")

    travel 61.minutes
    assert_empty sweep
    assert_nil @assistant.reload.stuck_alerted_at
  end

  private

  def sweep
    payloads = []
    original = WebPush.method(:payload_send)
    WebPush.define_singleton_method(:payload_send) { |message:, **| payloads << JSON.parse(message, symbolize_names: true) }
    StuckMailAlertJob.perform_now
    payloads
  ensure
    WebPush.define_singleton_method(:payload_send, original)
  end

  def send_task(caller, recipient, text)
    Task.open!(caller: caller, recipient: recipient).tap do |task|
      Message.record!(task: task, role: "ROLE_USER", sender: caller, parts: [ { "text" => text } ])
    end
  end
end
