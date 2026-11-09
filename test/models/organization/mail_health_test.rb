require "test_helper"

class Organization::MailHealthTest < ActiveSupport::TestCase
  setup do
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @organization = Organization.create!(name: "Health", slug: "health-org")
    @caller = create_agent("sender")
    @recipient = create_agent("assistant")
  end

  teardown { Rails.application.config.x.concourse.release_line = @previous_line }

  test "a SUBMITTED task counts from its caller message, over 15 minutes, then stuck at an hour" do
    freeze_time # the send and sent_at must share one second
    sent_at = Time.current
    task = send_task("please look")

    travel 14.minutes
    assert_equal [ 0, 0 ], counts(@recipient)
    travel 6.minutes
    assert_equal [ 1, 0 ], counts(@recipient)
    assert_not row(@recipient).stuck?, "15 minutes may only mean the agent is asking a person"
    travel 50.minutes
    assert_equal "TASK_STATE_SUBMITTED", task.reload.state
    assert_equal [ 1, 1 ], counts(@recipient), "SUBMITTED for 70 minutes is stuck"
    assert row(@recipient).stuck?
    assert_equal sent_at.to_i, row(@recipient).oldest_unanswered_at.to_i
    assert_equal [ 0, 0 ], counts(@caller), "the caller's own sent mail is not its unanswered mail"
  end

  test "a task with no caller message has nothing to answer" do
    Task.open!(caller: @caller, recipient: @recipient)

    travel 2.hours
    assert_equal [ 0, 0 ], counts(@recipient)
  end

  test "WORKING acknowledged two hours ago is not counted" do
    task = send_task("roll this out")
    task.transition_to!("TASK_STATE_WORKING", by: @recipient)
    Message.record!(task: task, role: "ROLE_AGENT", sender: @recipient, parts: [ { "text" => "On it; waiting on Ajay's browser." } ])

    travel 2.hours
    assert_equal [ 0, 0 ], counts(@recipient)
    assert_not row(@recipient).stuck?
  end

  test "a move to WORKING alone is a recipient action" do
    send_task("roll this out").transition_to!("TASK_STATE_WORKING", by: @recipient)

    travel 2.hours
    assert_equal [ 0, 0 ], counts(@recipient)
  end

  test "WORKING, then a new caller message 70 minutes ago, is stuck" do
    task = send_task("roll this out")
    task.transition_to!("TASK_STATE_WORKING", by: @recipient)
    Message.record!(task: task, role: "ROLE_AGENT", sender: @recipient, parts: [ { "text" => "On it." } ])

    travel 3.hours
    request(task, "any news?")
    asked_at = Time.current
    travel 70.minutes
    assert_equal [ 1, 1 ], counts(@recipient)
    assert_equal asked_at.to_i, row(@recipient).oldest_unanswered_at.to_i, "the clock starts at the newest caller message"

    Message.record!(task: task, role: "ROLE_AGENT", sender: @recipient, parts: [ { "text" => "Still going." } ])
    assert_equal [ 0, 0 ], counts(@recipient), "a recipient reply answers it"
  end

  test "a recipient artifact is a recipient action" do
    task = send_task("draft it")
    Artifact.record!(task: task, by: @recipient, parts: [ { "text" => "draft" } ])

    travel 2.hours
    assert_equal "TASK_STATE_SUBMITTED", task.reload.state
    assert_equal [ 0, 0 ], counts(@recipient)
  end

  test "an input request waits on the caller until the caller answers" do
    task = send_task("book it")
    task.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @recipient)

    travel 2.hours
    assert_equal [ 0, 0 ], counts(@recipient)

    request(task, "here you go")
    answered_at = Time.current
    travel 20.minutes
    assert_equal [ 1, 0 ], counts(@recipient), "the clock starts at the answer, not at the question"
    assert_equal answered_at.to_i, row(@recipient).oldest_unanswered_at.to_i
  end

  test "a terminal task never counts" do
    send_task("done soon").transition_to!("TASK_STATE_COMPLETED", by: @recipient)
    send_task("never mind").cancel_by_caller!(by: @caller)

    travel 2.hours
    assert_equal [ 0, 0 ], counts(@recipient)
  end

  test "mail from a caller no longer admitted is out of the recipient's reach and not counted" do
    send_task("hello")
    @caller.retire

    travel 2.hours
    assert_equal [ 0, 0 ], counts(@recipient)
  end

  test "feed lag is the events after the cursor, and stalls after an hour" do
    task = Task.open!(caller: @caller, recipient: @recipient)
    assert_nil row(@recipient).feed, "an agent that never acknowledged a cursor does not use the feed"

    request(task, "first")
    AgentEvent.acknowledge!(@recipient, 1)
    feed = row(@recipient).feed
    assert_equal 0, feed.lag
    assert_nil feed.oldest_unread_at
    assert_not feed.stalled?

    travel 1.minute
    request(task, "second")
    sent_at = Time.current
    feed = row(@recipient).feed
    assert_equal 1, feed.lag
    assert_equal sent_at.to_i, feed.oldest_unread_at.to_i
    assert_not feed.stalled?

    travel 61.minutes
    assert row(@recipient).feed.stalled?
    assert row(@recipient).stuck?

    AgentEvent.acknowledge!(@recipient, 2)
    assert_not row(@recipient).feed.stalled?
  end

  test "a webhook alone marks an agent as a feed reader" do
    register_push
    assert_equal 0, row(@recipient).feed.lag
  end

  test "the row carries the webhook's last outcome" do
    config = register_push
    assert_not row(@recipient).push.failing?

    config.undelivered!
    config.undelivered!
    push = row(@recipient).push
    assert push.failing?
    assert_equal 2, push.consecutive_failures

    config.delivered!
    push = row(@recipient).push
    assert_not push.failing?
    assert push.last_succeeded_at
  end

  test "only admitted, named agents outside the platform have rows" do
    unnamed_owner = User.create!(handle: "unnamed", ajent_sub: "health-unnamed", organizations: [ @organization ])
    Agent.create!(owner: unnamed_owner, organization: @organization, oauth_client_id: "client-unnamed")

    handles = @organization.mail_health.rows.map { |row| row.agent.qualified_handle }
    assert_equal [ "assistant/assistant", "sender/sender" ], handles
  end

  private

  def create_agent(handle)
    owner = User.create!(handle: handle, ajent_sub: "health-#{handle}", organizations: [ @organization ])
    Agent.create!(owner: owner, organization: @organization, handle: handle, oauth_client_id: "client-#{handle}")
  end

  def row(agent)
    @organization.mail_health.rows.find { |row| row.agent.id == agent.id }
  end

  def counts(agent)
    row(agent).then { |row| [ row.slow, row.stuck ] }
  end

  def request(task, text)
    Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => text } ])
  end

  # A send: the task and the caller's message, as A2a::Exchange records them.
  def send_task(text)
    Task.open!(caller: @caller, recipient: @recipient).tap { |task| request(task, text) }
  end

  # Skips the public-address check, which would resolve the host.
  def register_push
    config = @recipient.build_push_config(url: "https://hooks.example.com/concourse", token: "push-token-0123456789abcdef")
    config.save!(validate: false)
    config
  end
end
