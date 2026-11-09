require "test_helper"

class OwnerAlertJobTest < ActiveJob::TestCase
  setup do
    @previous = Rails.application.config.x.vapid
    key = WebPush.generate_key
    Rails.application.config.x.vapid = { subject: "mailto:test@example.com", public_key: key.public_key, private_key: key.private_key }

    @ajay = User.create!(ajent_sub: "42", handle: "ajay", organizations: [ Organization.default ])
    @riley = User.create!(ajent_sub: "7", handle: "riley", organizations: [ Organization.default ])
    @codex = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a")
    @pi = Agent.create!(owner: @riley, handle: "pi", oauth_client_id: "client-b")
    @subscription = @ajay.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/abc", p256dh_key: "p", auth_key: "a")
  end

  teardown { Rails.application.config.x.vapid = @previous }

  test "a task waiting on my agent queues an alert after the grace period" do
    task = nil
    assert_enqueued_with(job: OwnerAlertJob, at: OwnerAlertJob::GRACE.from_now) do
      task = Task.open!(recipient: @codex, caller: @pi)
    end
    payloads = deliveries { perform_enqueued_jobs }

    assert_equal 1, payloads.size
    assert_equal "New task for ajay/codex", payloads.first[:title]
    assert_equal "/#{task.organization.slug}/tasks/#{task.id}", payloads.first[:path]
  end

  test "an input request on a task my agent sent alerts me without its content" do
    task = Task.open!(recipient: @pi, caller: @codex)
    clear_enqueued_jobs
    message = Message.record!(task: task, role: "ROLE_AGENT", sender: @pi, parts: [ { "text" => "secret-sentinel" } ])
    task.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @pi, status_message: message)

    payloads = deliveries { perform_enqueued_jobs }

    assert_equal [ "riley/pi needs input" ], payloads.map { |payload| payload[:title] }
    assert_not_includes payloads.to_json, "secret-sentinel"
  end

  test "no alert when the task moved during the grace period" do
    task = Task.open!(recipient: @codex, caller: @pi)
    task.transition_to!("TASK_STATE_WORKING", by: @codex)

    assert_empty(deliveries { perform_enqueued_jobs })
  end

  test "no alert once the caller has answered the input request" do
    task = Task.open!(recipient: @pi, caller: @codex)
    task.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @pi)
    Message.record!(task: task, role: "ROLE_USER", sender: @codex, parts: [ { "text" => "here" } ])

    assert_empty(deliveries { perform_enqueued_jobs })
  end

  test "nothing is queued for owners with no subscription, or without VAPID keys" do
    assert_no_enqueued_jobs(only: OwnerAlertJob) { Task.open!(recipient: @pi, caller: @pi) }

    Rails.application.config.x.vapid = {}
    assert_no_enqueued_jobs(only: OwnerAlertJob) { Task.open!(recipient: @codex, caller: @pi) }
  end

  test "an expired subscription is removed" do
    Task.open!(recipient: @codex, caller: @pi)
    response = Struct.new(:code, :body).new("410", "")
    with_payload_send(->(**) { raise WebPush::ExpiredSubscription.new(response, "fcm.googleapis.com") }) do
      perform_enqueued_jobs
    end

    assert_not PushSubscription.exists?(@subscription.id)
  end

  private

  def deliveries
    payloads = []
    with_payload_send(->(message:, **) { payloads << JSON.parse(message, symbolize_names: true) }) { yield }
    payloads
  end

  # Minitest 6 has no stub; swap the one network call and put it back.
  def with_payload_send(fake)
    original = WebPush.method(:payload_send)
    WebPush.define_singleton_method(:payload_send) { |**options| fake.call(**options) }
    yield
  ensure
    WebPush.define_singleton_method(:payload_send, original)
  end
end
