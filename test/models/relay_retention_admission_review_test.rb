require "test_helper"

class RelayRetentionAdmissionReviewTest < ActiveSupport::TestCase
  setup do
    @organization = Organization.default
    caller_owner = User.create!(ajent_sub: "admission-caller", handle: "admission-caller", organizations: [ @organization ])
    recipient_owner = User.create!(ajent_sub: "admission-recipient", handle: "admission-recipient", organizations: [ @organization ])
    @caller = Agent.create!(owner: caller_owner, handle: "caller")
    @recipient = Agent.create!(owner: recipient_owner, handle: "recipient")
    @task = Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient, execution_route: "native")
    @mapping = RelayTask.create!(task: @task, organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      endpoint_url: "https://native.invalid/a2a", resource: "https://native.invalid/a2a", generation: 1,
      native_task_id: "upstream", native_context_id: "context")
    @mapping.import_snapshot!({ "id" => "upstream", "contextId" => "context", "status" => { "state" => "TASK_STATE_WORKING" },
      "history" => [ { "messageId" => "native-message", "role" => "ROLE_AGENT", "contextId" => "context", "parts" => [ { "text" => "private-marker" } ] } ] })
    @request = { "messageId" => "orphan", "taskId" => @task.id, "role" => "ROLE_USER", "parts" => [ { "text" => "orphan-private-marker" } ] }
  end

  %i[caller recipient].each do |removed_side|
    test "agent reads exclude native content when #{removed_side} is removed before counting and pagination" do
      removed = instance_variable_get("@#{removed_side}")
      viewer = removed_side == :caller ? @recipient : @caller
      assert_equal 1, A2a::Exchange.list_tasks(viewer: viewer, filters: {}).fetch("totalSize")
      removed.owner.memberships.find_by!(organization: @organization).destroy!
      assert viewer.admitted?
      assert_not @task.reload.participants_admitted?
      assert_raises(A2a::Error) { A2a::Exchange.get_task(viewer: viewer, id: @task.id) }
      listed = A2a::Exchange.list_tasks(viewer: viewer, filters: { "pageSize" => 1, "includeArtifacts" => true })
      assert_equal 0, listed.fetch("totalSize")
      assert_empty listed.fetch("tasks")
      assert_equal "", listed.fetch("nextPageToken")
      assert_empty Task.visible_to(viewer)
    end
  end

  test "recipient inbox does not disclose retained inbox content after caller removal" do
    task = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "inbox-private-marker" } ])
    assert_equal 1, A2a::Exchange.inbox(@recipient).size
    @caller.owner.memberships.find_by!(organization: @organization).destroy!
    assert_empty A2a::Exchange.inbox(@recipient)
    assert_nil A2a::Exchange.with_limits(inbox: 0) { A2a::Exchange.next_task(@recipient) }
  end

  %w[reserved sending].each do |phase|
    test "retention resolves orphaned #{phase} phase without releasing dedupe or fabricating cancellation" do
      receipt = reserve(@request)
      receipt.start_sending!(holder: "crashed", deadline_at: 10.seconds.from_now) if phase == "sending"
      before_fence = receipt.fence
      receipt.update_columns(content_changed_at: 31.days.ago, deadline_at: 31.days.ago)
      PurgeExpiredTasksJob.perform_now
      RelaySweepJob.perform_now
      assert Task.exists?(@task.id), "fresh native content outlives this old receipt"
      assert receipt.reload.expired_at?
      assert_equal phase == "sending" ? "held" : "rejected", receipt.phase
      assert_equal phase == "sending" ? "unconfirmed" : "abandoned", receipt.outcome
      assert_operator receipt.fence, :>, before_fence
      assert_nil receipt.request_payload
      assert_nil receipt.result_payload
      assert_nil receipt.holder
      assert_nil receipt.deadline_at
      assert_not_includes receipt.attributes.to_json, "private-marker"
      assert_empty RelayDelivery.pending.where(id: receipt.id)
      tombstone = receipt.attributes
      receipt.expire!
      assert_equal tombstone, receipt.reload.attributes, "expiry remains idempotent"
      assert_raises(RelayDelivery::Expired) { reserve(@request) }
      assert_raises(RelayDelivery::Expired) { receipt.accept!(holder: "crashed", fence: before_fence, result: {}) }
      # Exercise the actual cancellation admission path and its partial unique index.
      # Hard-off rejects BEFORE token/HTTP, but only AFTER a distinct cancellation receipt exists.
      error = assert_raises(A2a::RelayError) do
        A2a::Exchange.cancel_task(caller: @caller, recipient: @recipient, id: @task.id)
      end
      assert_equal "RELAY_OUTBOUND_DISABLED", error.data.first.fetch("reason")
      assert_equal 1, @task.relay_deliveries.where(operation: "CancelTask").count
      assert_equal "TASK_STATE_WORKING", @task.reload.state
      assert_equal "native", @task.execution_route
      fresh = @request.merge("messageId" => "fresh")
      if phase == "sending"
        assert @task.input_delivery_unconfirmed?
        assert_raises(RelayDelivery::Busy) { reserve(fresh) }
      else
        assert_not @task.input_delivery_unconfirmed?
        assert_equal "reserved", reserve(fresh).phase
      end
    end
  end

  private

  def reserve(message)
    RelayDelivery.reserve!(caller: @caller, recipient: @recipient, task: @task, message: message,
      execution_route: "native", route_snapshot: @mapping.route_snapshot)
  end
end
