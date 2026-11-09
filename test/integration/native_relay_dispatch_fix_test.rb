require_relative "native_relay_delivery_test"

# Correct-outcome regressions for dispatch review findings 1-4. All provider
# entries and pauses are synthetic; no HTTP listener or model is involved.
class NativeRelayDispatchFixTest < ActionDispatch::IntegrationTest
  include NativeRelayTestSupport
  setup { setup_native_relay }

  test "artifact-only polling cannot settle a blocking input on an old interruption" do
    # A2A §3.2.2 / relay plan §11: settlement must follow this input, not a
    # snapshot-base change which merely repeats an earlier INPUT_REQUIRED.
    travel_to Time.utc(2026, 10, 7, 12) do
      snapshot = native_task(state: "TASK_STATE_INPUT_REQUIRED", timestamp: Time.current.iso8601)
      response = ->(request, _) { native_response(request, result: { "task" => snapshot.deep_dup }) }
      with_native(response: response) do
        task = Task.find(rpc_native.dig("result", "task", "id"))
        old_status = task.events.where(kind: "status").sole
        old_status_at = task.status_at
        mapping = task.relay_task
        exchange = A2a::Exchange.new(@caller)
        elapsed = 0.0
        idle_count = 0
        polled = snapshot.deep_dup.merge("artifacts" => [ { "artifactId" => "poll-only", "parts" => [ { "text" => "progress" } ] } ])
        idle = ->(_) do
          idle_count += 1
          mapping.import_snapshot!(polled) if idle_count == 1
          # Give the first poll a real opportunity to settle before expiring
          # the synthetic wait on its second idle; no timing-sensitive sleep.
          elapsed += 0.6
        end
        error = nil
        replace_method(exchange, :monotonic, -> { elapsed }) do
          replace_method(A2a::Waiters, :idle, idle) do
            A2a::Exchange.with_limits(blocking: 1, poll: 0.1) do
              error = assert_raises(A2a::RelayError) do
                exchange.send_message(@recipient, user_message(id: "blocking-input", task_id: task.id), {})
              end
            end
          end
        end
        assert_equal "RELAY_WAIT_LIMIT", error.data.sole["reason"]
        assert_equal task.id, error.data.sole.dig("metadata", "taskId")
        assert_equal 2, idle_count
        assert_equal [ old_status.id ], task.events.where(kind: "status").pluck(:id)
        assert_equal old_status_at, task.reload.status_at
        assert_equal "TASK_STATE_INPUT_REQUIRED", task.state
        assert_equal snapshot["status"]["timestamp"], task.events.where(kind: "status").sole.upstream_timestamp
        boundary = task.events.where(kind: "snapshot_boundary").sole
        assert_not boundary.settlement_evidence
        assert_operator boundary.id, :>, old_status.id
        assert_equal "poll-only", task.artifacts.sole.native_artifact_id
        delivery = task.relay_deliveries.find_by!(message_id_digest: Digest::SHA256.hexdigest("blocking-input"))
        assert_equal "accepted", delivery.phase
        assert_equal old_status.id, delivery.after_sequence
        assert_equal delivery.after_sequence, task.messages.find_by!(native_message_id: "blocking-input").native_after_sequence
        assert task.caller_answered?
        assert_not task.awaiting?(@caller.owner)
        assert_not Task.awaiting_owner(@caller.owner).exists?(task.id)
        assert_equal 0, task.relay_deliveries.where(operation: "CancelTask").count
        assert_equal 0, Task.inbox.count
        assert_equal 2, @calls.size
      end
    end
  end

  test "same-clock new question changes logical owner waiting but repeated status and freshness do not" do
    # A2A §3.2.2: logical native status/input order is not wall-clock order.
    travel_to Time.utc(2026, 10, 7, 12) do
      snapshot = native_task(state: "TASK_STATE_INPUT_REQUIRED", timestamp: Time.current.iso8601)
      snapshot["status"]["message"] = { "messageId" => "question-one", "role" => "ROLE_AGENT",
        "taskId" => "native-task", "contextId" => "native-context", "parts" => [ { "text" => "first question" } ] }
      response = ->(request, _) { native_response(request, result: { "task" => snapshot.deep_dup }) }
      with_native(response: response) do
        task = Task.find(rpc_native.dig("result", "task", "id"))
        mark = task.status_at
        old_sequence = task.events.where(settlement_evidence: true).maximum(:id)
        assert_equal "caller", task.waiting_side
        assert task.awaiting?(@caller.owner)
        assert Task.awaiting_owner(@caller.owner).exists?(task.id)
        input = user_message(id: "same-clock-input", task_id: task.id, context_id: task.context_id)
        assert_equal task.id, rpc_native(message: input).dig("result", "task", "id")
        caller_message = task.messages.find_by!(native_message_id: "same-clock-input")
        delivery = task.relay_deliveries.find_by!(message_id_digest: Digest::SHA256.hexdigest(input["messageId"]))
        assert_equal old_sequence, delivery.after_sequence
        assert_equal old_sequence, caller_message.native_after_sequence
        assert_equal mark, caller_message.created_at
        assert_equal mark, task.reload.status_at
        assert task.caller_answered?
        assert_nil task.waiting_side
        assert_not Task.awaiting_owner(@caller.owner).exists?(task.id)

        mapping = task.relay_task
        mapping.update!(stale: true)
        repeated = snapshot.deep_dup
        repeated["status"]["timestamp"] = 1.second.from_now.iso8601
        count = task.events.count
        2.times { mapping.import_snapshot!(repeated) }
        assert_equal count, task.events.count
        assert_not mapping.reload.stale
        assert_equal Time.current, mapping.observed_at
        assert_equal 1.second.from_now, mapping.upstream_status_at
        assert_equal mark, task.reload.status_at
        assert task.caller_answered?
        assert_not task.awaiting?(@caller.owner)
        assert_not Task.awaiting_owner(@caller.owner).exists?(task.id)

        question = snapshot.deep_dup
        question["status"]["message"]["messageId"] = "question-two"
        question["status"]["message"]["parts"] = [ { "text" => "second question" } ]
        mapping.import_snapshot!(question)
        event = task.events.where(kind: "status", settlement_evidence: true).order(:id).last
        assert_operator event.id, :>, caller_message.native_after_sequence
        assert_equal snapshot["status"]["timestamp"], event.upstream_timestamp
        assert_equal mark, task.reload.status_at
        assert_equal "question-two", task.status_message.native_message_id
        assert_not task.caller_answered?
        assert_equal "caller", task.waiting_side
        assert task.awaiting?(@caller.owner)
        assert Task.awaiting_owner(@caller.owner).exists?(task.id)
        assert_not Task.awaiting_owner(@recipient.owner).exists?(task.id)
        count = task.events.count
        mapping.import_snapshot!(question)
        assert_equal count, task.events.count
        assert task.reload.awaiting?(@caller.owner)
        assert_equal 2, @calls.size
      end
    end
  end

  test "sender paused after sending CAS cannot post after recovery and reassignment of both capacity slots" do
    # Relay plan §§8,12: lease expiry cannot grant a second dispatch path.
    travel_to Time.utc(2026, 10, 7, 12) do
      successors = []
      receipt = original_slot = nil
      paused = false
      exchange = A2a::Exchange.new(@caller)
      participant_check = exchange.method(:assert_delivery_participants!)
      test_case = self
      organization = @caller.organization
      pause = -> do
        participant_check.call
        current = exchange.instance_variable_get(:@delivery)
        if !paused && current.phase == "sending"
          paused = true
          receipt = current
          original_slot = RelayNetworkSlot.find_by!(kind: "dispatch", holder: receipt.holder)
          test_case.travel 16.seconds
          A2a::Exchange.recover_delivery!(receipt)
          test_case.assert_equal "held", receipt.reload.phase
          test_case.assert receipt.task.held?
          2.times do |index|
            holder = "dispatch-successor-#{index}"
            slot = RelayNetworkSlot.acquire(kind: :dispatch, organization: organization, holder: holder)
            test_case.assert slot
            successors << [ holder, slot ]
          end
          test_case.assert_includes successors.map { |_, slot| slot.id }, original_slot.id
        end
      end
      begin
        with_native(response: ->(*) { flunk "expired pre-HTTP sender must never enter native post" }) do
          error = nil
          replace_method(exchange, :assert_delivery_participants!, pause) do
            error = assert_raises(A2a::RelayError) { exchange.send_message(@recipient, user_message, { "returnImmediately" => true }) }
          end
          assert paused
          assert_equal "RELAY_DELIVERY_PENDING", error.data.sole["reason"]
          assert_empty @calls
          assert_equal [ ROUTE[:resource] ], @token_calls
          assert_equal "held", receipt.reload.phase
          task = receipt.task
          assert task.held?
          assert_not task.actionable?
          assert task.input_delivery_unconfirmed?
          assert_nil task.relay_task
          assert_equal "TASK_STATE_SUBMITTED", task.state
          assert_equal 0, Task.inbox.count
          assert_empty A2a::Exchange.inbox(@recipient)
          assert_equal task.id, rpc_native.dig("result", "task", "id")
          assert_empty @calls
          assert_equal 1, RelayDelivery.count
          successors.each { |holder, slot| assert slot.reload.held_by?(holder) }
          assert_equal 2, RelayNetworkSlot.where(kind: "dispatch", organization: @caller.organization).where("expires_at > ?", Time.current).count
        end
      ensure
        successors.each { |holder, slot| slot.release(holder) }
      end
    end
  end

  test "provider admission callback renews a freshly loaded owned slot within the sending deadline" do
    travel_to Time.utc(2026, 10, 7, 12) do
      response = ->(request, arguments) do
        receipt = RelayDelivery.sole
        slot = RelayNetworkSlot.find_by!(kind: "dispatch", holder: receipt.holder)
        travel 1.second
        slot.update_columns(expires_at: 2.seconds.from_now)
        assert arguments.fetch(:admission).call
        assert_equal 15.seconds.from_now, slot.reload.expires_at
        assert slot.held_by?(receipt.holder)
        assert_equal "sending", receipt.reload.phase
        assert_operator receipt.deadline_at, :>, Time.current
        native_response(request, result: { "task" => native_task(state: "TASK_STATE_COMPLETED") })
      end
      with_native(response: response) do
        body = rpc_native
        assert_equal "TASK_STATE_COMPLETED", body.dig("result", "task", "status", "state")
        assert_equal "accepted", RelayDelivery.sole.phase
        assert_equal 1, @calls.size
        assert_equal 0, RelayNetworkSlot.where.not(holder: nil).count
      end
    end
  end

  test "provider admission callback refuses a hard emergency egress flip before synthetic HTTP bytes" do
    wrote_http = false
    response = ->(request, arguments) do
      replace_method(Agent, :native_outbound_available?, -> { false }) do
        arguments.fetch(:admission).call
        wrote_http = true
        native_response(request, result: { "task" => native_task })
      end
    end
    with_native(response: response) do
      body = rpc_native
      assert_equal "RELAY_DELIVERY_PENDING", reason(body)
      assert_not wrote_http
      assert_nil RelayDelivery.sole.result_payload
      assert_equal 0, Task.count
      assert_equal 1, @calls.size # Provider entry, not an HTTP write.
      assert_equal 0, RelayNetworkSlot.where.not(holder: nil).count
    end
  end

  %i[caller recipient].each do |side|
    test "provider admission callback freshly checks #{side} admission before synthetic HTTP bytes" do
      wrote_http = false
      response = ->(request, arguments) do
        participant = side == :caller ? @caller : @recipient
        participant.owner.memberships.where(organization: participant.organization).delete_all
        arguments.fetch(:admission).call
        wrote_http = true
        native_response(request, result: { "task" => native_task })
      end
      with_native(response: response) do
        body = rpc_native
        assert_equal(-32001, body.dig("error", "code"))
        assert_not wrote_http
        receipt = RelayDelivery.sole
        assert receipt.expired_at
        assert_nil receipt.request_payload
        assert_nil receipt.result_payload
        assert_equal 0, Task.count
        assert_equal 1, @calls.size # Provider entry, not an HTTP write.
        assert_equal 0, RelayNetworkSlot.where.not(holder: nil).count
      end
    end
  end

  test "late verified initial Message retires the ghost Task while retaining scoped replay and dedupe" do
    # A2A §3.1.1: a Message-only acceptance supplies no Task state to invent.
    travel_to Time.utc(2026, 10, 7, 12) do
      tracking_id = nil
      response = ->(request, _) do
        receipt = RelayDelivery.sole
        holder, fence = receipt.holder, receipt.fence
        travel 11.seconds
        A2a::Exchange.recover_delivery!(receipt)
        task = receipt.reload.task
        tracking_id = task.id
        assert task.held?
        assert task.input_delivery_unconfirmed?
        assert @recipient.native_route_locked?
        assert_equal holder, receipt.holder
        assert_equal fence, receipt.fence
        native_response(request, result: { "message" => { "messageId" => "late-message", "role" => "ROLE_AGENT",
          "contextId" => "native-context", "parts" => [ { "text" => "verified late answer" } ], "metadata" => { "kept" => true } } })
      end
      with_native(response: response) do
        body = rpc_native
        assert_not body.key?("error"), body.inspect
        message = body.dig("result", "message")
        assert_equal "late-message", message.fetch("messageId")
        assert_equal({ "kept" => true }, message["metadata"])
        assert_not message.key?("taskId")
        assert_not body["result"].key?("task")
        receipt = RelayDelivery.sole
        digest = receipt.request_digest
        assert_equal "accepted", receipt.phase
        assert_equal "accepted", receipt.outcome
        assert_equal "native", receipt.execution_route
        assert_nil receipt.expired_at
        assert_nil receipt.task_id
        assert_equal tracking_id, receipt.reserved_task_id
        assert_equal({ "message" => message }, receipt.result_payload)
        assert_not Task.exists?(tracking_id)
        assert_equal 0, Task.count
        assert_equal 0, Message.count
        assert_equal 0, RelayTask.count
        assert_equal 0, TaskEvent.count
        assert_not RelayDelivery.pending.exists?
        assert_not @recipient.reload.native_route_locked?
        assert_empty A2a::Exchange.inbox(@recipient)
        assert_equal(-32001, rpc_native(method: "GetTask", params: { "id" => tracking_id }).dig("error", "code"))
        assert_equal body, rpc_native
        assert_equal(-32602, rpc_native(message: user_message(text: "changed payload")).dig("error", "code"))
        stranger = Agent.create!(owner: @recipient.owner, handle: "other-recipient", oauth_client_id: "other-recipient")
        assert_equal(-32602, rpc_native(recipient: stranger).dig("error", "code"))
        assert_equal digest, receipt.reload.request_digest
        assert_equal 1, @calls.size
        assert_equal 1, RelayDelivery.count
        assert_equal 0, Task.count

        travel 31.days
        PurgeExpiredTasksJob.perform_now
        assert receipt.reload.expired_at
        assert_nil receipt.request_payload
        assert_nil receipt.result_payload
        assert_equal digest, receipt.request_digest
        assert_equal "RELAY_RECORD_EXPIRED", reason(rpc_native)
        assert_equal 1, @calls.size
        assert_equal 1, RelayDelivery.count
        assert_equal 0, Task.count
        assert_not @recipient.reload.native_route_locked?
      end
    end
  end

  test "day-31 expired direct continuation retains exact caller evidence and accepts only legitimate native echoes" do
    # A2A §§4.1.4,13.1 / relay plan §§6,9: echoed ROLE_USER content needs
    # retained caller proof in this task/route, not the expired receipt body.
    travel_to Time.utc(2026, 10, 7, 12) do
      started = Time.current
      echo = nil
      response = ->(request, _) do
        result = if request.dig("params", "message", "taskId")
          echo = request.dig("params", "message").deep_dup
          { "message" => { "messageId" => "direct-answer", "role" => "ROLE_AGENT", "taskId" => "native-task",
            "contextId" => "native-context", "parts" => [ { "text" => "input accepted" } ] } }
        else
          { "task" => native_task(state: "TASK_STATE_INPUT_REQUIRED", timestamp: started.iso8601) }
        end
        native_response(request, result: result)
      end
      with_native(response: response) do
        task = Task.find(rpc_native.dig("result", "task", "id"))
        status = task.attributes.slice("state", "status_at", "status_message_id")
        input = user_message(id: "retained-direct-input", task_id: task.id, context_id: task.context_id, text: "exact caller answer")
        input["parts"][0]["metadata"] = { "part" => 7 }
        input["metadata"] = { "case" => "retention", "nested" => { "answer" => 7 } }
        input["extensions"] = [ "urn:test:retained-input" ]
        input["referenceTaskIds"] = [ task.id ]
        send_input = -> do
          A2a::Exchange.send_message(caller: @caller, recipient: @recipient, message: input,
            configuration: { "returnImmediately" => true }, via: "owner")
        end
        answer = send_input.call
        assert_instance_of A2a::DirectMessage, answer
        assert_equal task.id, answer.to_h["taskId"]
        assert_equal task.context_id, answer.to_h["contextId"]
        assert_equal status, task.reload.attributes.slice("state", "status_at", "status_message_id")
        receipt = task.relay_deliveries.find_by!(message_id_digest: Digest::SHA256.hexdigest(input["messageId"]))
        assert_equal "accepted", receipt.phase
        assert_equal 2, task.messages.where(role: "ROLE_USER", sender_agent: @caller).count
        row = task.messages.find_by!(native_message_id: input["messageId"], role: "ROLE_USER")
        expected = { "sender_agent_id" => @caller.id, "role" => "ROLE_USER", "client_message_id" => input["messageId"],
          "native_message_id" => input["messageId"], "native_task_id" => "native-task", "native_context_id" => "native-context",
          "parts" => input["parts"], "metadata" => input["metadata"].merge("concourse.via" => "owner"),
          "extensions" => input["extensions"], "reference_task_ids" => [ task.id ], "created_at" => receipt.created_at,
          "native_after_sequence" => receipt.after_sequence }
        assert_equal expected, row.attributes.slice(*expected.keys)
        internal_id = row.message_id
        after_sequence = receipt.after_sequence
        assert_equal started, row.created_at
        assert_operator after_sequence, :>, 0

        travel_to started + 29.days
        mapping = task.relay_task
        progress = native_task(state: "TASK_STATE_WORKING", timestamp: Time.current.iso8601)
        mapping.import_snapshot!(progress)
        assert_equal Time.current, task.reload.content_changed_at
        travel_to started + 31.days
        PurgeExpiredTasksJob.perform_now
        assert_equal started + 31.days, Time.current
        assert Task.exists?(task.id)
        assert RelayTask.exists?(mapping.id)
        assert receipt.reload.expired_at
        assert_nil receipt.request_payload
        assert_nil receipt.result_payload
        assert_equal after_sequence, receipt.after_sequence
        assert_equal expected, row.reload.attributes.slice(*expected.keys)
        error = assert_raises(A2a::RelayError) { send_input.call }
        assert_equal "RELAY_RECORD_EXPIRED", error.data.sole["reason"]
        assert_equal 2, @calls.size

        legitimate = native_task(state: "TASK_STATE_WORKING", timestamp: Time.current.iso8601).merge("history" => [ echo ])
        mapping.import_snapshot!(legitimate)
        assert_equal "TASK_STATE_WORKING", task.reload.state
        assert_equal internal_id, task.messages.find_by!(native_message_id: input["messageId"]).message_id
        assert_equal expected, row.reload.attributes.slice(*expected.keys)
        assert_equal 2, task.messages.where(role: "ROLE_USER", sender_agent: @caller).count
        event_count = task.events.count
        digest = mapping.reload.snapshot_digest
        forgeries = {
          "parts" => ->(message) { message["parts"] = [ { "text" => "invented answer" } ] },
          "part metadata" => ->(message) { message["parts"][0]["metadata"] = { "part" => 8 } },
          "message metadata" => ->(message) { message["metadata"]["nested"]["answer"] = 8 },
          "extensions" => ->(message) { message["extensions"] = [ "urn:test:forged-input" ] },
          "references" => ->(message) { message["referenceTaskIds"] = [] },
          "message ID" => ->(message) { message["messageId"] = "never-authored" },
          "task association" => ->(message) { message["taskId"] = "another-native-task" },
          "context association" => ->(message) { message["contextId"] = "another-native-context" }
        }
        forgeries.each do |name, forge|
          forged = legitimate.deep_dup
          forge.call(forged["history"].sole)
          assert_raises(RelayTask::InvalidSnapshot, name) { mapping.import_snapshot!(forged) }
          assert_equal digest, mapping.reload.snapshot_digest, name
          assert_equal event_count, task.events.count, name
          assert_equal expected, row.reload.attributes.slice(*expected.keys), name
        end
        assert_equal 2, @calls.size
        assert_equal 2, RelayDelivery.count
        assert_equal 1, Task.count
        assert_equal 0, Task.inbox.count
      end
    end
  end
end
