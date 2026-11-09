require "test_helper"
require "timeout"

class V3DeliveryRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @old_release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    suffix = SecureRandom.hex(6)
    @org = Organization.create!(name: "Synthetic v3 race", slug: "race-#{suffix}")
    @owners = %w[caller recipient].map do |role|
      User.create!(handle: "#{role}-#{suffix}", ajent_sub: "race-#{role}-#{suffix}", organizations: [ @org ])
    end
    @caller, @recipient = @owners.map { |owner| Agent.create!(owner: owner, organization: @org, handle: "pi", oauth_client_id: "race-#{owner.handle}") }
    @task = Task.open!(caller: @caller, recipient: @recipient)
    @input = Message.record!(task: @task, sender: @caller, role: "ROLE_USER", parts: [ { "text" => "Synthetic race input" } ], message_id: SecureRandom.uuid)
    @connection = Agent::Connection.open!(@recipient, session_id: "race-session")
    @id = SecureRandom.uuid
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @old_release
    # These are this test's committed synthetic rows, not a global reset.
    @org&.tasks&.destroy_all
    @org&.relay_deliveries&.delete_all
    @org&.agents&.destroy_all
    @org&.destroy!
    @owners&.each(&:destroy!)
  end

  test "separate connections never both prompt and cancel the same queued claim" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    outcomes = race(
      -> { publish("prompt") },
      -> { A2a::Exchange.cancel_task(caller: @caller, recipient: @recipient, id: @task.id) }
    )
    assert_equal 1, outcomes.count { |entry| entry[:ok] }
    claim = @task.task_deliveries.sole
    if @task.reload.state == "TASK_STATE_CANCELED"
      assert_equal "canceled", claim.reload.phase
      assert_not outcomes[0][:ok]
    else
      assert_equal "prompting", claim.reload.phase
      assert outcomes[0][:ok]
      assert_not outcomes[1][:ok]
    end
  end

  test "separate connections admit exactly one distinct claim for one genuine caller message" do
    second_id = SecureRandom.uuid
    outcomes = race(
      -> { publish("accept", messageIds: [ @input.wire_message_id ]) },
      -> { publish("accept", claim_id: second_id, messageIds: [ @input.wire_message_id ]) }
    )
    assert_equal 1, outcomes.count { |entry| entry[:ok] }
    assert_equal 1, @task.task_deliveries.count
    assert_equal 1, TaskDeliveryMessage.where(message_id: @input.message_id).count # tenancy-ok: this test's genuine message ID
    assert_includes [ @id, second_id ], @task.task_deliveries.sole.id
  end

  # A2A1.0 §3.1.2: terminal means final; §3.3.1 does not grant universal exactly-once effects.
  test "separate connection continuation and completion cannot strand an accepted caller message" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    publish("start")
    continuation_id = SecureRandom.uuid
    outcomes = race(
      -> { publish("settle", state: "TASK_STATE_COMPLETED", parts: [ { "text" => "Explicit final result" } ]) },
      -> {
        A2a::Exchange.send_message(caller: @caller, recipient: @recipient,
          message: { "messageId" => continuation_id, "taskId" => @task.id, "role" => "ROLE_USER", "parts" => [ { "text" => "Concurrent caller instruction" } ] },
          configuration: { "returnImmediately" => true })
      }
    )
    assert_equal 1, outcomes.count { |entry| entry[:ok] }
    accepted = @task.messages.where(client_message_id: continuation_id).exists?
    if accepted
      assert outcomes[1][:ok]
      assert_not outcomes[0][:ok]
      assert_equal "TASK_STATE_WORKING", @task.reload.state
      assert_equal "running", @task.task_deliveries.sole.phase
    else
      assert outcomes[0][:ok]
      assert_not outcomes[1][:ok]
      assert_equal "TASK_STATE_COMPLETED", @task.reload.state
    end
  end

  private

  def publish(operation, claim_id: @id, **fields)
    envelope = { "operation" => operation, "id" => claim_id, "connectionId" => @connection.id, "sessionId" => @connection.session_id }
    envelope["messageIds"] = fields[:messageIds] if fields.key?(:messageIds)
    A2a::Exchange.reply(agent: @recipient, task_id: @task.id, delivery: envelope, state: fields[:state], parts: fields[:parts])
  end

  def race(*operations)
    ready = Queue.new
    go = Queue.new
    threads = operations.map do |operation|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          ready << connection.object_id
          go.pop
          begin
            { ok: true, result: operation.call }
          rescue StandardError => error
            { ok: false, error: error }
          end
        end
      end
    end
    ids = Timeout.timeout(10) { operations.size.times.map { ready.pop } }
    assert_equal operations.size, ids.uniq.size, "each operation has a distinct database connection"
    operations.size.times { go << true }
    Timeout.timeout(10) { threads.map(&:value) }
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end
end
