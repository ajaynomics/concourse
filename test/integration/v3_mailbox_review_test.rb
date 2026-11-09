require "test_helper"

class V3MailboxReviewTest < ActiveSupport::TestCase
  setup do
    @release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Mailbox review", slug: "mailbox-review")
    @caller = agent("review-caller")
    @recipient = agent("review-recipient")
    @task = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "request" } ])
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @release
  end

  test "ordinary consecutive questions need no artificial WORKING transition" do
    reply("first question")
    Message.record!(task: @task.reload, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "first answer" } ])
    reply("second question")
    result = A2a::Serializer.task(@task.reload)
    assert_equal "second question", result.dig("status", "message", "parts", 0, "text")
    assert_equal [ result.dig("status", "message", "messageId") ], result.dig("metadata", "concourse.output", "messageIds")
    assert_equal "caller", @task.waiting_side
  end

  test "ordinary unanswered question waits on caller rather than old unclaimed input" do
    reply("question")
    assert_equal "caller", @task.reload.waiting_side
    assert_includes Task.awaiting_owner(@caller.owner), @task
    assert_not_includes Task.awaiting_owner(@recipient.owner), @task
    A2a::Exchange.with_limits(inbox: 0) { assert_nil A2a::Exchange.next_task(@recipient) }
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "answer" } ])
    assert_equal "recipient", @task.reload.waiting_side
    assert_includes Task.awaiting_owner(@recipient.owner), @task
    assert_not_includes Task.awaiting_owner(@caller.owner), @task
    assert_equal @task, A2a::Exchange.next_task(@recipient)
  end

  test "equal clock input and new question use causal events while old restatement never revives question" do
    travel_to Time.utc(2026, 10, 13, 0, 0, 0) do
      reply("Q1")
      Message.record!(task: @task.reload, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "A1" } ])
      @task.restate!(by: @recipient)
      assert_equal "recipient", @task.reload.waiting_side
      assert_includes Task.awaiting_owner(@recipient.owner), @task
      assert_empty A2a::Serializer.task(@task).dig("metadata", "concourse.output", "messageIds")
      reply("Q2")
      assert_equal "caller", @task.reload.waiting_side
      assert_includes Task.awaiting_owner(@caller.owner), @task
      result = A2a::Serializer.task(@task)
      assert_equal [ result.dig("status", "message", "messageId") ], result.dig("metadata", "concourse.output", "messageIds")
    end
  end

  private

  def agent(handle)
    user = User.create!(handle: handle, ajent_sub: handle, organizations: [ @org ])
    Agent.create!(owner: user, organization: @org, handle: handle)
  end

  def reply(text)
    A2a::Exchange.reply(agent: @recipient, task_id: @task.id, state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => text } ])
  end
end
