require "test_helper"

class RelayFollowJobTest < ActiveJob::TestCase
  setup do
    @organization = Organization.default
    owner = User.create!(ajent_sub: "follow-a", handle: "caller", email: "caller@example.com", organizations: [ @organization ])
    recipient_owner = User.create!(ajent_sub: "follow-b", handle: "recipient", email: "recipient@example.com", organizations: [ @organization ])
    @caller = Agent.create!(owner: owner, handle: "a", oauth_client_id: "follow-a")
    @recipient = Agent.create!(owner: recipient_owner, handle: "b", oauth_client_id: "follow-b")
    @task = Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      execution_route: "native", context_id: "public-context", state: "TASK_STATE_SUBMITTED", status_at: Time.current)
    @relay = RelayTask.create!(task: @task, organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      endpoint_url: "https://native.example.com/a2a", resource: "https://native.example.com/a2a", generation: 1,
      native_task_id: "private-task", native_context_id: "private-context", next_follow_at: Time.current)
    @calls = []
    @response_status = 200
    @response_headers = {}
    @snapshot = { "id" => "private-task", "contextId" => "private-context", "status" => { "state" => "TASK_STATE_WORKING" } }
  end

  test "following uses scoped GetTask only and stores artifacts before terminal closure" do
    @snapshot["status"]["state"] = "TASK_STATE_COMPLETED"
    @snapshot["artifacts"] = [ { "artifactId" => "wire-file", "metadata" => { "x" => true }, "parts" => [ { "url" => "https://unfetched.invalid/file" } ] } ]
    follow
    assert_equal [ "GetTask" ], @calls.map { |call| call.dig("body", "method") }
    assert_equal "private-task", @calls.sole.dig("body", "params", "id")
    assert_equal @caller.qualified_handle, @calls.sole.dig("headers", "Concourse-Caller")
    assert_equal "TASK_STATE_COMPLETED", @task.reload.state
    assert_equal "wire-file", @task.artifacts.sole.native_artifact_id
    assert_nil @relay.reload.next_follow_at
    assert_nil @relay.lease_holder
  end

  test "identical polling snapshots update freshness without content or status watermarks" do
    follow
    watermark = @task.reload.status_at
    content = @task.content_changed_at
    events = @task.events.count
    travel 10.seconds do
      follow
      assert_equal watermark, @task.reload.status_at
      assert_equal content, @task.content_changed_at
      assert_equal events, @task.events.count
      assert_operator @relay.reload.observed_at, :>, watermark
    end
  end

  test "duplicate queued follows preserve the successful polling schedule until due" do
    follow
    scheduled = @relay.reload.attributes
    due = @relay.next_follow_at
    assert_in_delta 5, due - Time.current, 1
    follow
    assert_equal 1, @calls.size
    assert_equal scheduled, @relay.reload.attributes
    travel_to due, with_usec: true do
      follow
      assert_equal 2, @calls.size
      assert_equal 0, @relay.reload.follow_failures
      assert_equal due + 5.seconds, @relay.next_follow_at
    end
  end

  test "HTTP failures never fabricate FAILED or cause inbox fallback and backoff survives lease release" do
    @response_status = 503
    follow
    scheduled = @relay.reload.attributes
    first_due = @relay.next_follow_at
    follow
    assert_equal 1, @calls.size
    assert_equal 1, @relay.reload.follow_failures
    assert_equal scheduled, @relay.attributes
    travel_to first_due, with_usec: true do
      follow
      assert_equal 2, @calls.size
      assert_equal 2, @relay.reload.follow_failures
      assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
      assert_equal "native", @task.execution_route
      assert @relay.gap
      assert_operator @relay.next_follow_at, :>, first_due
      assert_operator @relay.next_follow_at, :>=, 10.seconds.from_now
      assert_nil @relay.lease_holder
    end
  end

  test "Retry-After is honored but capped at five minutes" do
    @response_status = 429
    @response_headers = { "retry-after" => "3600" }
    follow
    assert_in_delta 300, @relay.reload.next_follow_at - Time.current, 1
  end

  test "duplicate queued follows cannot bypass the 429 Retry-After schedule" do
    @response_status = 429
    @response_headers = { "retry-after" => "300" }
    follow
    scheduled = @relay.reload.attributes
    due = @relay.next_follow_at
    assert_in_delta 300, due - Time.current, 1
    follow
    assert_equal 1, @calls.size
    assert_equal scheduled, @relay.reload.attributes
    travel_to due - 1.second, with_usec: true do
      follow
      assert_equal 1, @calls.size
      assert_equal scheduled, @relay.reload.attributes
    end
    travel_to due, with_usec: true do
      follow
      assert_equal 2, @calls.size
      assert_equal 2, @relay.reload.follow_failures
      assert_equal due + 300.seconds, @relay.next_follow_at
    end
  end

  %w[text metadata].each do |field|
    test "invalid binary UTF8 in native #{field} exhausts following without importing or crashing" do
      @snapshot["artifacts"] = [ { "artifactId" => "wire", "parts" => [ { "text" => field == "text" ? "private-body" : "valid" } ] } ]
      @snapshot["metadata"] = { "provider" => "private-body" } if field == "metadata"
      @response_filter = ->(wire) { wire.b.sub("private-body", "private-body\xff".b).freeze }
      original = @task.attributes.slice("state", "execution_route", "status_at", "content_changed_at")
      follow
      assert_equal 1, @calls.size
      assert_equal original, @task.reload.attributes.slice(*original.keys)
      assert_empty @task.messages
      assert_empty @task.artifacts
      assert_equal [ "snapshot_boundary" ], @task.events.pluck(:kind)
      assert_not @task.events.sole.settlement_evidence
      assert @relay.reload.budget_exhausted
      assert_equal 1, @relay.follow_failures
      assert @relay.stale
      assert @relay.gap
      assert_nil @relay.observed_at
      assert_nil @relay.snapshot_digest
      assert_empty @relay.upstream_metadata
      assert_nil @relay.next_follow_at
      assert_nil @relay.lease_holder
      follow
      assert_equal 1, @calls.size
      assert_equal 1, @relay.reload.follow_failures
    end
  end

  test "auth rejection pauses following without a token refresh/resend" do
    @response_status = 401
    follow
    assert @relay.reload.auth_paused
    assert_nil @relay.next_follow_at
    follow
    assert_equal 1, @calls.size
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
  end

  test "removal during network observation cannot write native output or resurrect records" do
    @during_http = -> { @organization.memberships.find_by!(user: @recipient.owner).remove }
    follow
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
    assert_nil @relay.reload.observed_at
    assert_empty @task.artifacts
  end

  test "expired lease cannot import a late snapshot" do
    assert @relay.acquire_observation!(holder: "old")
    fence = @relay.fence
    @relay.update!(lease_expires_at: 1.second.ago)
    assert @relay.acquire_observation!(holder: "new")
    assert_raises(RelayTask::LostLease) { @relay.import_snapshot!(@snapshot, fence: fence) }
    assert_equal "TASK_STATE_SUBMITTED", @task.reload.state
    assert_not @relay.finish_observation!(holder: "old", fence: fence)
    assert_equal "new", @relay.reload.lease_holder
  end

  test "pending mutation blocks observation but held continuations do not reopen sends" do
    delivery = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, task: @task, execution_route: "native",
      route_snapshot: @relay.route_snapshot, message: { "messageId" => "pending", "parts" => [ { "text" => "input" } ] })
    assert_not @relay.acquire_observation!(holder: "observation")
    delivery.start_sending!(holder: "sender", deadline_at: 10.seconds.from_now)
    delivery.hold!(holder: "sender", fence: delivery.fence)
    assert @relay.acquire_observation!(holder: "observe-held")
    assert_raises(RelayDelivery::Busy) do
      RelayDelivery.reserve!(caller: @caller, recipient: @recipient, task: @task, execution_route: "native",
        route_snapshot: @relay.route_snapshot, message: { "messageId" => "bypass", "parts" => [ { "text" => "input" } ] })
    end
  end

  test "terminal observations never age into stale after following stops" do
    @snapshot["status"]["state"] = "TASK_STATE_COMPLETED"
    follow
    travel 2.minutes do
      assert_not @relay.reload.observation_stale?
      follow
      assert_equal 1, @calls.size
    end
  end

  test "emergency off does not observe or transfer native work to the inbox" do
    job = RelayFollowJob.new
    with_method(job, :egress_enabled?, -> { false }) { job.perform(@organization.id, @task.id) }
    assert @relay.reload.stale
    assert @relay.gap
    assert_equal "native", @task.reload.execution_route
    assert_equal "TASK_STATE_SUBMITTED", @task.state
  end

  test "captured streaming follows one scoped subscription and stores equal chunks before terminal state" do
    capture_streaming_route
    artifact = { "artifactId" => "wire", "parts" => [ { "text" => "chunk" } ] }
    ids = { "taskId" => "private-task", "contextId" => "private-context" }
    @stream_events = [ { "task" => @snapshot },
      { "artifactUpdate" => ids.merge("artifact" => artifact, "append" => false) },
      { "artifactUpdate" => ids.merge("artifact" => artifact, "append" => true) },
      { "statusUpdate" => ids.merge("status" => { "state" => "TASK_STATE_COMPLETED" }) } ]
    follow
    assert_equal [ "SubscribeToTask" ], @calls.map { |call| call.dig("body", "method") }
    assert_equal 2, @task.artifacts.sole.parts.size
    assert_equal %w[snapshot_boundary artifact artifact status], @task.events.order(:id).pluck(:kind)
    assert_equal "TASK_STATE_COMPLETED", @task.reload.state
    assert_nil @relay.reload.next_follow_at
  end

  test "SSE invalidated fence emergency off and removal prevent all later writes" do
    capture_streaming_route
    ids = { "taskId" => "private-task", "contextId" => "private-context" }
    @stream_events = [ { "task" => @snapshot }, { "statusUpdate" => ids.merge("status" => { "state" => "TASK_STATE_COMPLETED" }) } ]
    @during_stream = -> { @relay.reload.with_lock { @relay.invalidate_observation! } }
    follow
    assert_equal "TASK_STATE_WORKING", @task.reload.state
    assert_equal 0, @task.events.where(kind: "status").count
    assert_nil @relay.reload.lease_holder
  end

  test "SSE exact RPC ID and initial Task are required before observation" do
    capture_streaming_route
    @stream_events = [ { "task" => @snapshot } ]
    @wrong_stream_id = true
    follow
    assert @relay.reload.budget_exhausted
    assert_equal [ "snapshot_boundary" ], @task.events.pluck(:kind)
    assert_nil @relay.observed_at
  end

  test "SSE auth failure pauses rather than refreshing and polling a different route" do
    capture_streaming_route
    @stream_events = []
    @response_status = 401
    follow
    follow
    assert_equal 1, @calls.size
    assert @relay.reload.auth_paused
    assert_nil @relay.next_follow_at
  end

  private

  def capture_streaming_route
    attributes = @relay.attributes.except("id", "created_at", "updated_at")
    @relay.destroy!
    @relay = RelayTask.create!(attributes.merge("native_streaming" => true))
  end

  def follow
    transport = Object.new
    transport.define_singleton_method(:post) do |**args|
      body = JSON.parse(args.fetch(:body))
      @test.instance_variable_get(:@calls) << { "body" => body, "headers" => args.fetch(:headers) }
      @test.instance_variable_get(:@during_http)&.call
      wire = { "jsonrpc" => "2.0", "id" => body.fetch("id"), "result" => @test.instance_variable_get(:@snapshot) }.to_json
      wire = @test.instance_variable_get(:@response_filter)&.call(wire) || wire
      A2a::NativeTransport::Response.new(status: @test.instance_variable_get(:@response_status),
        body: wire, headers: @test.instance_variable_get(:@response_headers))
    end
    transport.define_singleton_method(:subscribe) do |**args, &emit|
      test = @test
      body = JSON.parse(args.fetch(:body))
      test.instance_variable_get(:@calls) << { "body" => body, "headers" => args.fetch(:headers) }
      args.fetch(:admission).call
      if test.instance_variable_get(:@response_status) == 200
        Array(test.instance_variable_get(:@stream_events)).each_with_index do |payload, index|
          test.instance_variable_get(:@during_stream)&.call if index > 0
          args.fetch(:on_tick).call
          id = test.instance_variable_get(:@wrong_stream_id) ? "foreign" : body.fetch("id")
          break if emit.call({ "jsonrpc" => "2.0", "id" => id, "result" => payload }) == false
        end
      end
      A2a::NativeTransport::Response.new(status: test.instance_variable_get(:@response_status), body: "",
        headers: test.instance_variable_get(:@response_headers))
    end
    transport.instance_variable_set(:@test, self)
    with_method(Ajent::RelayToken, :fetch, ->(**) { "synthetic-token" }) do
      with_method(A2a::NativeTransport, :new, ->(**) { transport }) do
        job = RelayFollowJob.new
        with_method(job, :egress_enabled?, -> { true }) { job.perform(@organization.id, @task.id) }
      end
    end
  end

  def with_method(object, name, implementation)
    original = object.method(name)
    own = object.singleton_class.instance_methods(false).include?(name)
    object.define_singleton_method(name, &implementation)
    yield
  ensure
    if own
      object.define_singleton_method(name, &original)
    else
      object.singleton_class.remove_method(name)
    end
  end
end
