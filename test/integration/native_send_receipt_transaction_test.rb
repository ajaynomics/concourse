require "test_helper"
require "timeout"
require "json_schemer"

# A2A v1.0 §3.3.1: these are local acceptance/rollback guarantees, not a
# cross-operation retry promise. SQLite serializes writers, not individual rows.
class NativeSendReceiptTransactionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    suffix = SecureRandom.hex(6)
    @org = Organization.create!(name: "Receipt transaction", slug: "receipt-tx-#{suffix}")
    @owners = 2.times.map { |i| User.create!(ajent_sub: "receipt-#{suffix}-#{i}", handle: "receipt-#{suffix}-#{i}", organizations: [ @org ]) }
    @caller, @recipient = @owners.map { |owner| Agent.create!(owner: owner, organization: @org, handle: "pi", oauth_client_id: "receipt-#{owner.handle}") }
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @release
    @org&.tasks&.destroy_all
    RelayDelivery.where(organization_id: @org.id).delete_all if @org
    @org&.agents&.destroy_all
    @org&.destroy!
    @owners&.each(&:destroy!)
  end

  test "failure after accepted receipt SQL update rolls back every local effect and fresh same wire retry records once" do
    wire = SecureRandom.uuid
    captured = nil
    callback = ->(delivery) do
      assert_equal "accepted", delivery.reload.phase
      captured = delivery.result_payload.deep_dup
      verify_pair(delivery.task, captured.fetch("sendReceipt"), wire)
      assert_equal 1, @org.tasks.count
      assert_equal 1, delivery.task.messages.count
      raise IOError, "synthetic failure after acceptance SQL update"
    end
    intercept_accept(callback) { assert_raises(IOError) { send_input(wire) } }
    assert captured
    assert_equal 0, @org.tasks.count
    assert_equal 0, @org.relay_deliveries.count
    assert_not TaskEvent.where(task_id: captured.dig("task", "id")).exists?, "this rolled-back synthetic Task has no surviving event"

    first = send_input(wire)
    replay = send_input(wire)
    assert_equal receipt(first), receipt(replay)
    assert_equal 1, @org.tasks.count
    assert_equal 1, @org.relay_deliveries.count
    assert_equal 1, @org.tasks.sole.messages.count
    verify_pair(@org.tasks.sole, receipt(first), wire)
  end

  test "independent connection cannot commit later input during captured receipt transaction" do
    seed = send_input(SecureRandom.uuid)
    task_id = seed.fetch("id")
    first_wire = SecureRandom.uuid
    later_wire = SecureRandom.uuid
    captured = Queue.new
    release = Queue.new
    callback = ->(delivery) do
      if delivery.request_payload.fetch("messageId") == first_wire
        delivery.class.connection_pool.with_connection do |connection|
          captured << [ delivery.result_payload.deep_dup, connection.object_id, connection.open_transactions ]
        end
        release.pop
      end
    end
    first = nil
    intercept_accept(callback) do
      first = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { send_input(first_wire, task_id: task_id) }
      end
      first.report_on_exception = false
      payload, first_connection, transactions = Timeout.timeout(10) { captured.pop }
      assert_operator transactions, :>, 0
      verify_pair(Task.find(task_id), receipt(seed), seed.dig("metadata", "concourse.send_receipt", "callerInput", "messageId"))
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        assert_not_equal first_connection, connection.object_id
        previous_timeout = connection.select_value("PRAGMA busy_timeout").to_i
        begin
          connection.raw_connection.busy_timeout = 0
          error = assert_raises(ActiveRecord::StatementInvalid) { send_input(later_wire, task_id: task_id) }
          assert_kind_of SQLite3::BusyException, error.cause
          assert_not connection.transaction_open?
          assert_not @org.relay_deliveries.where(message_id_digest: Digest::SHA256.hexdigest(later_wire)).exists?
          assert_not @org.tasks.find(task_id).messages.where(client_message_id: later_wire).exists?
        ensure
          connection.raw_connection.busy_timeout = previous_timeout
        end
      end
      release << true
      original = Timeout.timeout(10) { first.value }
      assert_equal payload.fetch("sendReceipt"), receipt(original)
      later = send_input(later_wire, task_id: task_id)
      replay = send_input(first_wire, task_id: task_id)
      assert_equal receipt(original), receipt(replay)
      assert_not_equal receipt(original), receipt(later)
      assert_equal later_wire, replay.dig("metadata", "concourse.caller_input", "messageId")
      task = @org.tasks.find(task_id)
      assert_equal 3, task.messages.count
      assert_equal 3, @org.relay_deliveries.count
      verify_pair(task, receipt(original), first_wire)
      verify_pair(task, receipt(later), later_wire)
    end
  ensure
    if first&.alive?
      release << true
      begin
        Timeout.timeout(5) { first.join }
      rescue Timeout::Error
        first.kill.join # Only this test's synthetic thread, never a process.
      end
    end
  end

  test "declared receipt schema rejects malformed cursor representations including terminal newline" do
    schema = JSONSchemer.schema(JSON.parse(JSON.generate(ConcourseMcp::Schemas::TASK)))
    body = send_input(SecureRandom.uuid)
    assert schema.valid?(body)
    [ "0", "01", "-1", "1.0", "1\n", 1, nil ].each do |cursor|
      malformed = body.deep_dup
      receipt(malformed).fetch("callerInput")["cursor"] = cursor
      assert_not schema.valid?(malformed), "invalid cursor must fail schema validation"
    end
  end

  private

  def send_input(wire, task_id: nil)
    message = { "messageId" => wire, "role" => "ROLE_USER", "parts" => [ { "text" => "Synthetic transaction evidence" } ] }
    message["taskId"] = task_id if task_id
    A2a::Exchange.new(@caller).send_message(@recipient, message, { "returnImmediately" => true })
  end

  def receipt(body)
    body.dig("metadata", "concourse.send_receipt")
  end

  def verify_pair(task, value, wire)
    pair = value.fetch("callerInput")
    assert_equal wire, pair.fetch("messageId")
    assert_match(/\A[1-9][0-9]*\z/, pair.fetch("cursor"))
    event = task.events.find(pair.fetch("cursor"))
    message = task.messages.find_by!(client_message_id: wire)
    assert_equal "caller_input", event.kind
    assert_equal message.message_id, event.payload.fetch("message_id")
  end

  def intercept_accept(callback)
    original = RelayDelivery.instance_method(:accept!)
    RelayDelivery.define_method(:accept!) do |**arguments|
      result = original.bind_call(self, **arguments)
      callback.call(self)
      result
    end
    yield
  ensure
    RelayDelivery.define_method(:accept!, original)
  end
end
