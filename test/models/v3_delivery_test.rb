require "test_helper"

class V3DeliveryTest < ActiveSupport::TestCase
  setup do
    @old_release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "V3 One", slug: "v3-one")
    @other_org = Organization.create!(name: "V3 Two", slug: "v3-two")
    @caller = agent(@org, "sender")
    @recipient = agent(@org, "receiver")
    @outsider = agent(@other_org, "outsider")
    @task = Task.open!(caller: @caller, recipient: @recipient)
    @input = Message.record!(task: @task, sender: @caller, role: "ROLE_USER", parts: [ { "text" => "untrusted peer work" } ], message_id: "input-one")
    @connection = Agent::Connection.open!(@recipient, session_id: "pi-session")
    @id = SecureRandom.uuid
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @old_release
  end

  test "admission does not imply processing or completion and settlement is exact replay" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    assert_equal "queued", receipt["state"]
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
    publish("prompt")
    assert_equal "delivered", receipt["state"]
    publish("start")
    assert_equal "running", receipt["state"]
    assert_equal "TASK_STATE_WORKING", @task.reload.state
    publish("settle", state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => "need input" } ])
    assert_equal "TASK_STATE_INPUT_REQUIRED", @task.reload.state
    assert_no_difference -> { Message.count } do
      publish("settle", state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => "need input" } ])
    end
    assert_raises(A2a::Error) { publish("settle", state: "TASK_STATE_COMPLETED") }
  end

  test "only definitely unstarted work can be canceled under the task lock" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    @task.cancel_by_caller!(by: @caller)
    assert_equal "TASK_STATE_CANCELED", @task.reload.state
    assert_raises(A2a::Error) { publish("prompt") }
  end

  test "prompting and unknown crash never fabricate canceled or permit takeover" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    assert_raises(Task::InvalidTransition) { @task.cancel_by_caller!(by: @caller) }
    @connection.update!(lease_expires_at: 1.second.ago)
    assert_equal "uncertain", receipt["state"]
    assert_raises(A2a::Error) { publish("start") }
    @connection = Agent::Connection.open!(@recipient, session_id: "pi-session")
    assert_raises(A2a::Error) { publish("accept", messageIds: [ @input.wire_message_id ]) }
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
  end

  test "same session queued reconnect rebinds only exact IDs" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    @connection.close!
    @connection = Agent::Connection.open!(@recipient, session_id: "pi-session")
    publish("accept", messageIds: [ @input.wire_message_id ])
    assert_equal @connection.id, @task.task_deliveries.sole.connection_id
    old = @connection
    @connection = Agent::Connection.open!(@recipient, session_id: "different-session")
    assert_raises(A2a::Error) { publish("accept", messageIds: [ @input.wire_message_id ]) }
    @connection = old
    publish("prompt")
  end

  test "caller IDs must be genuine unseen messages and WORKING continuations remain actionable" do
    assert_raises(A2a::Error) { publish("accept", messageIds: [ "guessed" ]) }
    assert_raises(A2a::Error) { publish("accept", messageIds: [ @input.wire_message_id, @input.wire_message_id ]) }
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    publish("start")
    assert_raises(A2a::Error) { publish("settle") }
    publish("settle", parts: [ { "text" => "continuing" } ])
    @id = SecureRandom.uuid
    assert_raises(A2a::Error) { publish("accept", messageIds: [ @input.wire_message_id ]) }
    second = Message.record!(task: @task.reload, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "more" } ], message_id: "input-two")
    assert_equal @task.id, A2a::Exchange.next_task(@recipient).id
    publish("accept", messageIds: [ second.wire_message_id ])
  end

  test "stale provenance other recipients and removed parties cannot publish" do
    assert_raises(A2a::Error) { A2a::Exchange.reply(agent: @recipient, task_id: @task.id, delivery: {}, state: "TASK_STATE_COMPLETED") }
    assert_raises(A2a::Error) { A2a::Exchange.reply(agent: @outsider, task_id: @task.id, delivery: envelope("accept", messageIds: [ @input.wire_message_id ])) }
    publish("accept", messageIds: [ @input.wire_message_id ])
    @org.memberships.find_by!(user: @caller.owner).destroy!
    assert_raises(A2a::Error) { publish("prompt") }
  end

  test "presence is leased and removal readmission does not resurrect old connection" do
    assert_equal "connected", Agent::Connection.presence(@recipient)["state"]
    travel 46.seconds do
      assert_equal "unknown", Agent::Connection.presence(@recipient)["state"]
    end
    @connection.close!
    assert_equal "disconnected", Agent::Connection.presence(@recipient)["state"]
    @connection = Agent::Connection.open!(@recipient, session_id: "pi-session")
    @org.memberships.find_by!(user: @recipient.owner).destroy!
    @org.memberships.create!(user: @recipient.owner)
    assert_not @connection.active?
  end

  test "long running work resumes transport after a bounded connection without replaying execution" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    publish("start")
    old = envelope("settle")
    @connection.close!
    @connection = Agent::Connection.open!(@recipient, session_id: "pi-session")
    assert_raises(A2a::Error) { publish("accept", messageIds: [ @input.wire_message_id ]) }
    assert_no_difference [ -> { Message.count }, -> { TaskEvent.count }, -> { TaskDelivery.count } ] do
      publish("resume")
      publish("resume")
    end
    claim = @task.task_deliveries.sole
    assert_equal "running", claim.phase
    assert_equal [ @input.wire_message_id ], claim.message_ids
    assert_equal @connection.id, claim.connection_id
    assert_equal "TASK_STATE_WORKING", @task.reload.state
    assert_raises(A2a::Error) { A2a::Exchange.reply(agent: @recipient, task_id: @task.id, delivery: old, state: "TASK_STATE_COMPLETED") }
    publish("settle", state: "TASK_STATE_COMPLETED", parts: [ { "text" => "ongoing job finished" } ])
    assert_equal "TASK_STATE_COMPLETED", @task.reload.state
  end

  test "duplicate accept at advanced phases is idempotent only on the bound connection" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    %w[prompt start uncertain].each do |operation|
      publish(operation)
      phase = @task.task_deliveries.sole.phase
      assert_no_difference [ -> { TaskEvent.count }, -> { TaskDelivery.count } ] do
        publish("accept", messageIds: [ @input.wire_message_id ])
      end
      assert_equal phase, @task.task_deliveries.sole.phase
    end
    @connection = Agent::Connection.open!(@recipient, session_id: "pi-session")
    assert_raises(A2a::Error) { publish("accept", messageIds: [ @input.wire_message_id ]) }
    publish("resume")
    assert_equal "uncertain", @task.task_deliveries.sole.phase
    assert_raises(A2a::Error) { publish("start") }
    assert_raises(A2a::Error) { publish("settle", state: "TASK_STATE_COMPLETED") }
  end

  test "resume never admits work, changes session or resets message IDs" do
    assert_raises(A2a::Error) { publish("resume") }
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    other_connection = Agent::Connection.open!(@recipient, session_id: "another-session")
    old = @connection
    @connection = other_connection
    assert_raises(A2a::Error) { publish("resume") }
    @connection = old
    assert_raises(A2a::Error) { publish("resume", messageIds: [ "different" ]) }
    assert_equal "prompting", @task.task_deliveries.sole.phase
  end

  test "recipient removal invalidates claims even after readmission with the old connection" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    @org.memberships.find_by!(user: @recipient.owner).destroy!
    assert_raises(A2a::Error) { publish("start") }
    @org.memberships.create!(user: @recipient.owner)
    assert_raises(A2a::Error) { publish("resume") }
    assert_equal "prompting", @task.task_deliveries.sole.phase
  end

  test "stale clean disconnect is unknown and presence instantiates only bounded candidates" do
    @connection.close!
    travel 46.seconds do
      assert_equal "unknown", Agent::Connection.presence(@recipient)["state"]
    end
    10.times do |index|
      connection = Agent::Connection.open!(@recipient, session_id: "connection-#{index}")
      connection.close!
    end
    instantiated = 0
    listener = ->(*args) do
      payload = args.last
      instantiated += payload[:record_count] if payload[:class_name] == "Agent::Connection"
    end
    ActiveSupport::Notifications.subscribed(listener, "instantiation.active_record") do
      assert_equal "disconnected", Agent::Connection.presence(@recipient)["state"]
    end
    assert_operator instantiated, :<=, 2
  end

  test "bounded old observation retention preserves referenced delivery receipts" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    @connection.close!
    @connection.update!(observed_at: 2.days.ago)
    105.times do |index|
      Agent::Connection.create!(id: SecureRandom.uuid, organization: @org, agent: @recipient,
        membership_id: @connection.membership_id, session_id: "old-#{index}",
        observed_at: 2.days.ago, closed_at: 2.days.ago, lease_expires_at: 2.days.ago, limit_at: 2.days.ago)
    end
    assert_difference -> { @recipient.connections.count }, -99 do
      Agent::Connection.open!(@recipient, session_id: "pi-session")
    end
    assert_difference -> { @recipient.connections.count }, -5 do
      Agent::Connection.prune!(@recipient)
    end
    assert @recipient.connections.exists?(@connection.id)
    assert_equal "queued", @task.task_deliveries.sole.phase
  end


  test "owner waiting tasks uses causal continuation after an explicit recipient report" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    publish("start")
    publish("settle", state: "TASK_STATE_WORKING", parts: [ { "text" => "first batch handled" } ])
    second = Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "still waiting" } ], message_id: "waiting-continuation")
    another = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: another, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "another task" } ], message_id: "other-waiting")
    assert @task.reload.actionable?
    assert_equal second.created_at, @task.actionable_since
    assert_equal [ @task.id, another.id ], @recipient.waiting_tasks(@org.tasks).map(&:id)
    assert_includes @org.tasks.awaiting_owner(@recipient.owner).pluck(:id), @task.id
  end

  test "content retention purges every claim phase atomically and releases old observation references" do
    fresh_id = @task.id
    expired_ids = []
    claim_ids = []
    %w[queued prompting running settled].each do |phase|
      @task = Task.open!(caller: @caller, recipient: @recipient)
      @input = Message.record!(task: @task, role: "ROLE_USER", sender: @caller,
        parts: [ { "text" => "expired claim content" } ], message_id: "expired-#{phase}")
      @id = SecureRandom.uuid
      publish("accept", messageIds: [ @input.wire_message_id ])
      publish("prompt") unless phase == "queued"
      publish("start") if phase.in?(%w[running settled])
      publish("settle", state: "TASK_STATE_COMPLETED", parts: [ { "text" => "expired outcome" } ]) if phase == "settled"
      assert_equal phase, @task.task_deliveries.sole.phase
      expired_ids << @task.id
      claim_ids << @id
      @task.update_columns(updated_at: 31.days.ago)
    end
    @connection.close!
    @connection.update!(observed_at: 31.days.ago)
    assert_no_difference -> { @recipient.connections.count } do
      Agent::Connection.prune!(@recipient)
    end
    PurgeExpiredTasksJob.perform_now
    assert_empty @org.tasks.where(id: expired_ids)
    assert_empty TaskDelivery.where(organization_id: @org.id).where(id: claim_ids)
    assert_empty TaskDeliveryMessage.where(task_delivery_id: claim_ids)
    assert_empty Message.where(task_id: expired_ids)
    assert @org.tasks.exists?(fresh_id)
    assert_equal 4, @org.relay_deliveries.where.not(expired_at: nil).count
    assert @org.relay_deliveries.all? { |delivery| delivery.request_payload.nil? && delivery.result_payload.nil? }
    assert_difference -> { @recipient.connections.count }, -1 do
      Agent::Connection.prune!(@recipient)
    end
  end

  test "physical recipient removal cascades claim references before destroying its connections" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    publish("start")
    task_id = @task.id
    connection_id = @connection.id
    @recipient.destroy!
    assert_empty @org.tasks.where(id: task_id)
    assert_empty TaskDelivery.where(organization_id: @org.id).where(id: @id)
    assert_empty TaskDeliveryMessage.where(task_delivery_id: @id)
    assert_empty Agent::Connection.where(organization_id: @org.id).where(id: connection_id)
  end

  test "doorbell initialization failures release the slot even without a completed stream" do
    old_limit = A2a::Waiters.limit
    A2a::Waiters.reset!
    A2a::Waiters.limit = 1
    [ [ Agent::Connection, :open! ], [ Agent::Doorbell, :new ] ].each do |target, name|
      original = target.method(name)
      begin
        target.define_singleton_method(name) { |*args, **kwargs| raise ActiveRecord::ConnectionTimeoutError, "synthetic connection failure" }
        assert_no_difference -> { @recipient.connections.count } do
          assert_raises(ActiveRecord::ConnectionTimeoutError) { Agent::Doorbell.open(@recipient, session_id: "pi-session") }
        end
        assert A2a::Waiters.acquire(@org.id), "initialization failure leaked the only waiter slot"
      ensure
        target.define_singleton_method(name, original)
        A2a::Waiters.reset!
      end
    end
  ensure
    A2a::Waiters.limit = old_limit
    A2a::Waiters.reset!
  end

  test "doorbell capacity refusal neither opens presence nor fences an existing transport" do
    old_limit = A2a::Waiters.limit
    A2a::Waiters.reset!
    A2a::Waiters.limit = 1
    assert A2a::Waiters.acquire(@org.id)
    assert_no_difference -> { @recipient.connections.count } do
      assert_nil Agent::Doorbell.open(@recipient, session_id: "pi-session")
    end
    assert @connection.active?
  ensure
    A2a::Waiters.limit = old_limit
    A2a::Waiters.reset!
  end

  test "owner actionability follows explicit correspondence not optional execution claims" do
    assert_includes @org.tasks.awaiting_owner(@recipient.owner).pluck(:id), @task.id
    publish("accept", messageIds: [ @input.wire_message_id ])
    assert @task.reload.actionable?
    assert_includes @org.tasks.awaiting_owner(@recipient.owner).pluck(:id), @task.id
    publish("prompt")
    publish("start")
    assert_not @task.reload.actionable?
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller,
      parts: [ { "text" => "continuation before the question" } ], message_id: "board-continuation")
    publish("settle", state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => "new explicit question" } ])
    assert_not @task.reload.actionable?
    assert_equal "caller", @task.waiting_side
    assert_not_includes @org.tasks.awaiting_owner(@recipient.owner).pluck(:id), @task.id
    assert_includes @org.tasks.awaiting_owner(@caller.owner).pluck(:id), @task.id
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller,
      parts: [ { "text" => "answer after the question" } ], message_id: "board-answer")
    assert @task.reload.actionable?
    assert_equal "recipient", @task.waiting_side
    assert_includes @org.tasks.awaiting_owner(@recipient.owner).pluck(:id), @task.id
    assert_not_includes @org.tasks.awaiting_owner(@caller.owner).pluck(:id), @task.id
  end

  test "v3 output observation separates state-only final snapshots from retained progress" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    publish("start")
    A2a::Exchange.reply(agent: @recipient, task_id: @task.id, delivery: envelope("settle"),
      state: "TASK_STATE_WORKING", parts: [ { "text" => "progress, not a final answer" } ],
      artifacts: [ { "parts" => [ { "text" => "progress artifact" } ] } ])
    progress = A2a::Serializer.task(@task.reload)
    assert_equal [ progress.dig("status", "message", "messageId") ], progress.dig("metadata", "concourse.output", "messageIds")
    assert_equal progress.fetch("artifacts").pluck("artifactId"), progress.dig("metadata", "concourse.output", "artifactIds")
    continuation = Message.record!(task: @task, sender: @caller, role: "ROLE_USER",
      parts: [ { "text" => "finish without another answer" } ], message_id: "quiet-continuation")
    @id = SecureRandom.uuid
    publish("accept", messageIds: [ continuation.wire_message_id ])
    publish("prompt")
    publish("start")
    publish("settle", state: "TASK_STATE_COMPLETED")
    final = A2a::Exchange.get_task(viewer: @caller, id: @task.id)
    assert_equal progress.dig("status", "message"), final.dig("status", "message")
    assert_equal progress.fetch("artifacts"), final.fetch("artifacts")
    assert_equal [], final.dig("metadata", "concourse.output", "messageIds")
    assert_equal [], final.dig("metadata", "concourse.output", "artifactIds")
    assert_equal final.dig("status", "timestamp"), final.dig("metadata", "concourse.output", "statusTimestamp")
    Rails.application.config.x.concourse.release_line = 1
    assert_not A2a::Serializer.task(@task.reload).fetch("metadata", {}).key?("concourse.output")
  end

  test "accepted caller input supersedes a question even at the same timestamp without a new status" do
    travel_to(Time.current.change(usec: 0)) do
      publish("accept", messageIds: [ @input.wire_message_id ])
      publish("prompt")
      publish("start")
      travel(1.second)
      publish("settle", state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => "which environment?" } ])
      question = A2a::Serializer.task(@task.reload)
      assert_equal [ question.dig("status", "message", "messageId") ], question.dig("metadata", "concourse.output", "messageIds")
      result = A2a::Exchange.send_message(caller: @caller, recipient: @recipient,
        message: { "messageId" => "question-answer", "taskId" => @task.id, "role" => "ROLE_USER",
          "parts" => [ { "text" => "use the approved isolated environment" } ] },
        configuration: { "returnImmediately" => true })
      assert_equal "TASK_STATE_INPUT_REQUIRED", @task.reload.state
      assert_equal @task.status_at, @task.messages.find_by!(client_message_id: "question-answer").created_at
      assert_equal question.dig("status", "message"), result.dig("status", "message")
      assert_equal [], result.dig("metadata", "concourse.output", "messageIds")
      assert_equal [], result.dig("metadata", "concourse.output", "artifactIds")
      travel(1.second)
      @task.restate!(by: @recipient)
      assert_equal [], A2a::Serializer.task(@task.reload).dig("metadata", "concourse.output", "messageIds")
      travel(1.second)
      @id = SecureRandom.uuid
      publish("accept", messageIds: [ "question-answer" ])
      publish("prompt")
      publish("start")
      travel(1.second)
      publish("settle", state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => "which dataset?" } ])
      fresh = A2a::Serializer.task(@task.reload)
      assert_equal [ fresh.dig("status", "message", "messageId") ], fresh.dig("metadata", "concourse.output", "messageIds")
    end
  end

  test "caller input observations are internal and never become A2A status updates" do
    publish("accept", messageIds: [ @input.wire_message_id ])
    publish("prompt")
    publish("start")
    publish("settle", state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => "choose a value" } ])
    stream = A2a::Stream.task(@task.reload, viewer: @caller)
    continuation = Message.record!(task: @task, sender: @caller, role: "ROLE_USER",
      parts: [ { "text" => "chosen value" } ], message_id: "stream-answer")
    @id = SecureRandom.uuid
    publish("accept", messageIds: [ continuation.wire_message_id ])
    publish("prompt")
    publish("start")
    publish("settle", state: "TASK_STATE_COMPLETED")
    frames = []
    stream.each { |frame| frames << frame if frame }
    assert_equal [ "TASK_STATE_WORKING", "TASK_STATE_COMPLETED" ],
      frames.drop(1).map { |frame| frame.dig("statusUpdate", "status", "state") }
  end

  private

  def agent(org, handle)
    owner = User.create!(handle: handle, ajent_sub: "v3-#{handle}", email: "#{handle}@example.test", organizations: [ org ])
    Agent.create!(owner: owner, organization: org, handle: "pi", oauth_client_id: "v3-#{handle}")
  end

  def envelope(operation, **extra)
    { "operation" => operation, "id" => @id, "connectionId" => @connection.id, "sessionId" => @connection.session_id }.merge(extra.stringify_keys.except("parts", "state"))
  end

  def publish(operation, **extra)
    A2a::Exchange.reply(agent: @recipient, task_id: @task.id, delivery: envelope(operation, **extra), parts: extra[:parts], state: extra[:state])
  end

  def receipt
    TaskDelivery.receipt(@task.reload)
  end
end
