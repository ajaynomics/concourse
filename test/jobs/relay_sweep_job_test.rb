require "test_helper"

class RelaySweepJobTest < ActiveJob::TestCase
  setup do
    @organization = Organization.default
    owner = User.create!(ajent_sub: "sweep-a", handle: "caller", email: "caller@example.com", organizations: [ @organization ])
    other = User.create!(ajent_sub: "sweep-b", handle: "recipient", email: "recipient@example.com", organizations: [ @organization ])
    @caller = Agent.create!(owner: owner, handle: "a", oauth_client_id: "sweep-a")
    @recipient = Agent.create!(owner: other, handle: "b", oauth_client_id: "sweep-b")
  end

  test "sweep recovers lost observation enqueue from persisted due time" do
    task = Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      execution_route: "native", context_id: "public-context", state: "TASK_STATE_WORKING", status_at: Time.current)
    RelayTask.create!(task: task, organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      endpoint_url: "https://native.example.com/a2a", resource: "https://native.example.com/a2a", generation: 1,
      native_task_id: "native", next_follow_at: 5.seconds.ago)
    assert_enqueued_with(job: RelayFollowJob, args: [ @organization.id, task.id ]) { RelaySweepJob.perform_now }
    assert_equal "native", task.reload.execution_route
  end

  test "orphaned sending receipt is held without repeating any mutation" do
    delivery = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, execution_route: "native",
      route_snapshot: { endpoint_url: "https://native.example.com/a2a", resource: "https://native.example.com/a2a", generation: 1 },
      message: { "messageId" => "orphan", "parts" => [ { "text" => "request" } ] })
    delivery.start_sending!(holder: "original", deadline_at: 10.seconds.from_now)
    travel 11.seconds do
      assert_no_enqueued_jobs(only: RelayFollowJob) { RelaySweepJob.perform_now }
      assert_equal "held", delivery.reload.phase
      assert_equal "unconfirmed", delivery.outcome
      assert_raises(RelayDelivery::Pending) { delivery.start_sending!(holder: "replacement", deadline_at: 10.seconds.from_now) }
    end
    assert_empty Task.inbox
  end

  test "normal queues cannot consume relay_follow and the due recovery is recurring" do
    queues = YAML.safe_load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true).fetch("production").fetch("workers")
    assert_includes queues.first.fetch("queues"), "default"
    assert_not_includes queues.first.fetch("queues"), "relay_follow"
    assert_equal 3, queues.first.fetch("threads")
    assert_equal "relay_follow", queues.second.fetch("queues")
    assert_equal 4, queues.second.fetch("threads")
    assert_equal 1, queues.second.fetch("processes")
    recurring = YAML.safe_load(Rails.root.join("config/recurring.yml").read)
    assert_equal "RelaySweepJob", recurring.dig("production", "recover_due_relay_tasks", "class")
  end
end
