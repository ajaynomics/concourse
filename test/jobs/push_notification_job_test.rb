require "test_helper"
require_relative "../support/push_hosts"

class PushNotificationJobTest < ActiveJob::TestCase
  include PushHosts

  TOKEN = "push-token-0123456789abcdef"

  setup do
    stub_push_hosts
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @organization = Organization.create!(name: "Push", slug: "push-org")
    @caller = create_agent("sender")
    @recipient = create_agent("assistant")
    @task = Task.open!(caller: @caller, recipient: @recipient)
  end

  teardown do
    restore_push_hosts
    Rails.application.config.x.concourse.release_line = @previous_line
  end

  test "an event enqueues a notification after commit, and only when the agent has a config" do
    assert_no_enqueued_jobs(only: PushNotificationJob) { request("no webhook yet") }

    register
    AgentEvent.transaction do
      request("inside a transaction")
      assert_no_enqueued_jobs only: PushNotificationJob
    end
    assert_enqueued_jobs 1, only: PushNotificationJob
  end

  test "posts references and the token, never content" do
    register
    sent = []
    stub_request(:post, PushHosts::HOOK).with { |request| sent << request }.to_return(status: 204)
    request("secret-sentinel")
    event = @recipient.event_log.sole

    perform_enqueued_jobs

    sent.sole.then do |request|
      assert_equal "application/json", request.headers["Content-Type"]
      assert_equal TOKEN, request.headers["X-A2a-Notification-Token"]
      assert_equal event.seq.to_s, request.headers["Concourse-Event-Id"]
      assert_equal({ "agent" => "assistant/assistant", "event_id" => event.seq, "task_id" => @task.id, "kind" => "message" },
        JSON.parse(request.body))
      assert_not_includes request.body, "secret-sentinel"
    end
  end

  test "connects to the address it checked, without a proxy, still naming the host for TLS" do
    config = register
    request("hello")
    event = @recipient.event_log.sole
    stub_request(:post, PushHosts::HOOK).to_return(status: 204)
    connections = []
    original_new = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*args| original_new.call(*args).tap { |http| connections << http } }

    assert config.deliver(event)

    http = connections.sole
    assert_equal PushHosts::ADDRESSES.fetch("hooks.example.com").first, http.ipaddr
    assert_equal "hooks.example.com", http.address
    assert http.use_ssl?
    assert_not http.proxy?
    assert_equal 0, http.max_retries
  ensure
    Net::HTTP.define_singleton_method(:new, original_new) if original_new
  end

  test "5xx, 429 and timeouts retry; 4xx and redirects are discarded" do
    config = register
    request("hello")
    event = @recipient.event_log.sole
    clear_enqueued_jobs

    { 500 => true, 503 => true, 429 => true, 404 => false, 401 => false, 302 => false }.each do |status, retried|
      stub_request(:post, PushHosts::HOOK).to_return(status: status)
      PushNotificationJob.perform_now(@organization.id, event.id)
      assert_equal retried, enqueued_jobs.any?, "status #{status}"
      clear_enqueued_jobs
    end

    stub_request(:post, PushHosts::HOOK).to_timeout
    PushNotificationJob.perform_now(@organization.id, event.id)
    assert_enqueued_jobs 1, only: PushNotificationJob

    stub_request(:post, PushHosts::HOOK).to_return(status: 200)
    assert config.deliver(event)
  end

  test "does nothing once the config is gone, the agent is retired or the URL turns private" do
    config = register
    request("hello")
    event = @recipient.event_log.sole
    hook = stub_request(:post, %r{\Ahttps://}).to_return(status: 200)
    clear_enqueued_jobs

    config.update_column(:url, "https://internal.example.com/hook")
    PushNotificationJob.perform_now(@organization.id, event.id)
    @recipient.retire
    config.update_column(:url, PushHosts::HOOK)
    PushNotificationJob.perform_now(@organization.id, event.id)
    @recipient.approve
    config.destroy
    PushNotificationJob.perform_now(@organization.id, event.id)

    assert_not_requested hook
    assert_no_enqueued_jobs only: PushNotificationJob
  end

  test "records failures, refused or with retries exhausted, until a success resets them" do
    config = register
    request("hello")
    event = @recipient.event_log.sole
    clear_enqueued_jobs
    updated_at = config.reload.updated_at

    stub_request(:post, PushHosts::HOOK).to_return(status: 404)
    PushNotificationJob.perform_now(@organization.id, event.id)
    assert_equal 1, config.reload.consecutive_failures
    assert config.last_failed_at

    stub_request(:post, PushHosts::HOOK).to_return(status: 503)
    PushNotificationJob.perform_now(@organization.id, event.id)
    assert_equal 1, config.reload.consecutive_failures, "a retry still pending is not yet a failure"
    # Four more attempts: each retry is enqueued by the one before it.
    4.times { perform_enqueued_jobs(only: PushNotificationJob) }
    assert_equal 2, config.reload.consecutive_failures, "the fifth attempt gives up"
    assert_no_enqueued_jobs only: PushNotificationJob

    stub_request(:post, PushHosts::HOOK).to_return(status: 204)
    PushNotificationJob.perform_now(@organization.id, event.id)
    config.reload
    assert_equal 0, config.consecutive_failures
    assert config.last_succeeded_at
    assert_equal updated_at, config.updated_at, "outcomes do not change when the agent last set its config"
  end

  private

  def create_agent(handle)
    owner = User.create!(handle: handle, ajent_sub: "push-#{handle}", organizations: [ @organization ])
    Agent.create!(owner: owner, organization: @organization, handle: handle, oauth_client_id: "client-#{handle}")
  end

  def register
    @recipient.create_push_config!(url: PushHosts::HOOK, token: TOKEN)
  end

  def request(text)
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => text } ])
  end
end
