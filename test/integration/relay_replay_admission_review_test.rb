require_relative "native_relay_delivery_test"

# A2A §13.1 supplies task visibility; removal ending both parties' access is
# Concourse policy. Raw SQL models an external writer without flushing Rails'
# request cache. These are synthetic/offline probes with completeness OFF.
class RelayReplayAdmissionReviewTest < ActionDispatch::IntegrationTest
  include NativeRelayTestSupport
  setup { setup_native_relay }

  %i[caller recipient].each do |side|
    test "accepted Message replay refuses externally removed #{side} after reservation" do
      receipt = accepted_message_receipt
      original = RelayDelivery.method(:reserve!)
      review = self
      replace_method(RelayDelivery, :reserve!, ->(**arguments) {
        found = original.call(**arguments)
        review.assert found.participants_admitted?
        review.send(:remove_externally, side)
        found
      }) do
        ActiveRecord::Base.cache do
          body = rpc_native
          assert_equal(-32001, body.dig("error", "code"))
          assert_not_includes body.to_json, "private-replay-marker"
        end
      end
      assert receipt.reload.expired_at?
      assert_nil receipt.result_payload
      assert_equal 1, RelayDelivery.count
      assert_equal 0, Task.count
      assert_equal 0, @calls.size
      assert_equal 0, @token_calls.size
      assert_not Agent.native_relay_complete?
    end

    test "cached agent reads and receipt replay stop after external #{side} removal but owner history stays" do
      receipt = accepted_message_receipt
      task = Task.open!(caller: @caller, recipient: @recipient)
      Message.record!(task: task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "private-inbox-marker" } ])
      membership = instance_variable_get("@#{side}").owner.memberships.find_by!(organization: @caller.organization)
      ActiveRecord::Base.cache do
        assert receipt.replay!
        assert @caller.admitted?
        assert @recipient.admitted?
        assert_equal 1, A2a::Exchange.list_tasks(viewer: @caller, filters: {}).fetch("totalSize")
        assert_equal 1, A2a::Exchange.inbox(@recipient).size
        assert_equal task.id, A2a::Exchange.with_limits(inbox: 0) { A2a::Exchange.next_task(@recipient) }.id
        remove_externally(side, membership: membership)
        listed = A2a::Exchange.list_tasks(viewer: @caller, filters: {})
        assert_equal 0, listed.fetch("totalSize")
        assert_empty listed.fetch("tasks")
        assert_equal "", listed.fetch("nextPageToken")
        assert_empty A2a::Exchange.inbox(@recipient)
        assert_nil A2a::Exchange.with_limits(inbox: 0) { A2a::Exchange.next_task(@recipient) }
        assert_not task.participants_admitted?
        assert_not instance_variable_get("@#{side}").admitted?
        assert_raises(A2a::Error) { A2a::Exchange.get_task(viewer: @caller, id: task.id) }
        assert_raises(Agent::Unadmitted) { receipt.replay! }
      end
      remaining = side == :caller ? @recipient : @caller
      assert remaining.admitted?
      assert_equal [ task.id ], task.organization.tasks.involving_owner(remaining.owner).pluck(:id)
      assert_equal "private-inbox-marker", task.messages.sole.parts.sole.fetch("text")
    end

    test "HTTP accepted Message replay rechecks #{side} after authentication and reservation" do
      accepted_message_receipt
      original = RelayDelivery.method(:reserve!)
      review = self
      with_memory_cache do
        stub_agent_token("review-token", sub: @caller.owner.ajent_sub, client_id: @caller.oauth_client_id)
        replace_method(RelayDelivery, :reserve!, ->(**arguments) {
          found = original.call(**arguments)
          review.assert found.participants_admitted?
          review.send(:remove_externally, side)
          found
        }) do
          body = rpc(owner: @recipient.owner.handle, agent: @recipient.handle, token: "review-token", method: "SendMessage",
            params: { message: user_message, configuration: { returnImmediately: true } })
          assert_response :success
          assert_equal(-32001, body.dig("error", "code"))
          assert_not_includes body.to_json, "private-replay-marker"
        end
      end
      assert RelayDelivery.sole.expired_at?
      assert_nil RelayDelivery.sole.result_payload
      assert_equal 0, Task.count
      assert_equal 0, @calls.size
      assert_not Agent.native_relay_complete?
    end

    test "held replay and continuation refuse externally removed #{side} without changing executor" do
      receipt = accepted_message_receipt(held: true)
      assert_equal receipt.task_id, rpc_native.dig("result", "task", "id")
      remove_externally(side)
      assert_equal(-32001, rpc_native.dig("error", "code"))
      body = rpc_native(message: user_message(id: "follow-up", task_id: receipt.task_id))
      assert_equal(-32001, body.dig("error", "code"))
      assert receipt.reload.task.held?
      assert_equal "TASK_STATE_SUBMITTED", receipt.task.state
      assert_equal 1, RelayDelivery.count
      assert_equal 0, @calls.size
      assert_equal 0, @token_calls.size
      assert_empty A2a::Exchange.inbox(@recipient)
      assert_not Agent.native_relay_complete?
    end

    test "HTTP replay refuses removed #{side} with relay OFF and no new execution" do
      accepted_message_receipt
      with_memory_cache do
        stub_agent_token("review-token", sub: @caller.owner.ajent_sub, client_id: @caller.oauth_client_id)
        remove_externally(side)
        body = rpc(owner: @recipient.owner.handle, agent: @recipient.handle, token: "review-token", method: "SendMessage",
          params: { message: user_message, configuration: { returnImmediately: true } })
        assert body["error"]
        assert_response(side == :caller ? :forbidden : :success)
        assert_not_includes body.to_json, "private-replay-marker"
      end
      assert_equal 1, RelayDelivery.count
      assert_equal 0, Task.count
      assert_equal 0, @calls.size
      assert_not Agent.native_relay_complete?
    end
  end

  test "held replay cannot bypass a receipt expiry between reservation and response" do
    receipt = accepted_message_receipt(held: true)
    original = RelayDelivery.method(:reserve!)
    replace_method(RelayDelivery, :reserve!, ->(**arguments) {
      found = original.call(**arguments)
      RelayDelivery.find(found.id).expire!
      found
    }) do
      body = rpc_native
      assert_equal "RELAY_RECORD_EXPIRED", reason(body)
      assert_not body.key?("result")
    end
    assert receipt.reload.expired_at?
    assert receipt.task.held?
    assert_not receipt.task.actionable?
    assert_equal 0, @calls.size
    assert_not Agent.native_relay_complete?
  end

  test "held initial send remains on its route when activation is OFF" do
    receipt = accepted_message_receipt(held: true)
    first = rpc_native
    assert_equal receipt.task_id, first.dig("result", "task", "id")
    assert_equal "held", first.dig("result", "task", "metadata", "concourse.route")
    assert_equal first, rpc_native
    body = rpc_native(message: user_message(id: "follow-up", task_id: receipt.task_id))
    assert_equal "RELAY_DELIVERY_UNCONFIRMED", reason(body)
    assert_empty A2a::Exchange.inbox(@recipient)
    assert_equal 1, RelayDelivery.count
    assert_equal 0, @calls.size
    assert_equal 0, @token_calls.size
    assert_not Agent.native_relay_complete?
  end

  test "retention expiry revokes an already loaded accepted Message receipt" do
    receipt = accepted_message_receipt
    RelayDelivery.find(receipt.id).expire!
    assert_raises(RelayDelivery::Expired) { receipt.replay! }
    assert_nil receipt.result_payload
    assert_not_includes receipt.attributes.to_json, "private-replay-marker"
  end

  private

  def accepted_message_receipt(held: false)
    normalized = A2a::Exchange.new(@caller).send(:normalized_delivery_message, user_message, via: nil)
    digest = Digest::SHA256.hexdigest(RelayDelivery.canonical_json({ "message" => normalized, "metadata" => {}, "acceptedOutputModes" => [] }))
    receipt = RelayDelivery.reserve!(caller: @caller, recipient: @recipient, message: normalized,
      execution_route: "native", route_snapshot: ROUTE, request_digest: digest)
    receipt.start_sending!(holder: "synthetic", deadline_at: 10.seconds.from_now)
    receipt.accept!(holder: "synthetic", fence: receipt.fence, result: { "message" => {
      "messageId" => "native-answer", "contextId" => "public-context", "role" => "ROLE_AGENT", "parts" => [ { "text" => "private-replay-marker" } ] } }) unless held
    if held
      task = Task.create!(id: receipt.reserved_task_id, organization: @caller.organization, caller_agent: @caller,
        recipient_agent: @recipient, execution_route: "held")
      receipt.hold!(holder: "synthetic", fence: receipt.fence, task: task)
    end
    receipt
  end

  def remove_externally(side, membership: nil)
    agent = instance_variable_get("@#{side}")
    membership ||= agent.owner.memberships.find_by!(organization: agent.organization)
    ActiveRecord::Base.connection.raw_connection.execute("DELETE FROM memberships WHERE id = #{Integer(membership.id)}")
  end
end
