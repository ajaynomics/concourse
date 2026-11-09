require "test_helper"

class RecipientSendRefusalTest < ActiveSupport::TestCase
  setup do
    @old_release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Reply boundaries", slug: "reply-boundaries")
    @caller, @recipient, @stranger = %w[sender receiver stranger].map do |handle|
      owner = User.create!(ajent_sub: "reply-#{handle}", handle: "reply-#{handle}", email: "#{handle}@example.test", organizations: [ @org ])
      Agent.create!(owner: owner, organization: @org, handle: "pi")
    end
    @task = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, message_id: "original", parts: [ { "text" => "request" } ])
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @old_release
  end

  test "a recipient sending backwards gets a definite use-reply refusal before any write" do
    [ nil, @task.context_id ].each do |context|
      assert_no_difference [ -> { Task.count }, -> { Message.count }, -> { RelayDelivery.count }, -> { TaskEvent.count } ] do
        error = assert_raises(A2a::Error) { send_input(@recipient, @caller, context: context) }
        assert_equal(-32004, error.code)
        # A2A v1.0 §9.5: spec ErrorInfo remains first; Concourse detail follows.
        assert_equal [ [ "UNSUPPORTED_OPERATION", "a2a-protocol.org" ], [ "REPLY_REQUIRED", "concourse.krishnan.ca" ] ],
          error.to_h.fetch(:data).map { |info| info.values_at("reason", "domain") }
        assert_match "recipient reply", error.message
      end
    end
  end

  test "outsiders and missing tasks reveal no recipient-role information" do
    # A2A v1.0 §13.1: visibility precedes any explanation about an existing task.
    [ [ @stranger, @caller, @task.id ], [ @recipient, @caller, SecureRandom.uuid ] ].each do |caller, recipient, id|
      error = assert_raises(A2a::Error) { send_input(caller, recipient, id: id) }
      assert_equal(-32001, error.code)
      assert_not_includes error.to_h.to_json, "REPLY_REQUIRED"
    end
  end

  test "the original caller cannot continue with a different recipient" do
    error = assert_raises(A2a::Error) { send_input(@caller, @stranger) }
    assert_equal(-32001, error.code)
  end

  test "caller continuations and self-sends remain valid" do
    assert_difference -> { Message.count } do
      task = send_input(@caller, @recipient)
      assert_equal @task.id, task.fetch("id")
    end
    own = Task.open!(caller: @caller, recipient: @caller)
    assert_difference -> { Message.count } do
      assert_equal own.id, send_input(@caller, @caller, id: own.id).fetch("id")
    end
  end

  test "the legacy recipient-filtered refusal is unchanged" do
    Rails.application.config.x.concourse.release_line = 2
    error = assert_raises(A2a::Error) { send_input(@recipient, @caller) }
    assert_equal(-32001, error.code)
    assert_not_includes error.to_h.to_json, "REPLY_REQUIRED"
  end

  private

  def send_input(caller, recipient, id: @task.id, context: nil)
    message = { "messageId" => SecureRandom.uuid, "taskId" => id, "role" => "ROLE_USER", "parts" => [ { "text" => "follow-up" } ] }
    message["contextId"] = context if context
    A2a::Exchange.send_message(caller: caller, recipient: recipient, message: message, configuration: { "returnImmediately" => true })
  end
end
