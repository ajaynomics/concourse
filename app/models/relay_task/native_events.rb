class RelayTask
  module NativeEvents
    # Raw ProtoJSON StreamResponse, not SDK internal unions (§3.1.6, §9.4).
    def observe_native_event!(payload:, holder:, fence:, observed_at: Time.current)
      raise InvalidSnapshot unless payload.is_a?(Hash) && payload.to_json.bytesize <= SNAPSHOT_LIMIT
      keys = %w[task message statusUpdate artifactUpdate].select { |key| payload.key?(key) }
      raise InvalidSnapshot unless keys.one? && (payload.keys - keys).empty?
      value = payload.fetch(keys.first).deep_dup
      with_lock do
        task.reload.lock!
        raise LostLease unless owns_observation?(holder, fence)
        raise Agent::Unadmitted unless task.participants_admitted?
        case keys.first
        when "task" then observe_native_base!(value, observed_at)
        when "message" then observe_native_message!(value, observed_at)
        when "statusUpdate" then observe_native_status!(value, observed_at)
        when "artifactUpdate" then observe_native_artifact!(value, observed_at)
        end
        check_native_task_budget!
        check_retained_budget!
        update!(observed_at: observed_at, stale: false, follow_failures: 0)
      end
      task.reload
    rescue A2a::NativeResult::Invalid
      raise InvalidSnapshot
    end

    private

    def observe_native_base!(snapshot, now)
      A2a::NativeResult.validate_task!(snapshot)
      validate_snapshot!(snapshot)
      raise InvalidSnapshot if task.terminal? && task.state != snapshot.dig("status", "state")
      context = context_for_messages(snapshot)
      if native_context_id.nil? && context && native_message_context.nil?
        RelayContext.map!(caller: caller_agent, recipient: recipient_agent, generation: generation,
          public_context_id: task.context_id, native_context_id: context)
      end
      before = native_base_digest
      message = nil
      history = Array(snapshot["history"])
      position_base = native_history_offset(history)
      history.each_with_index do |wire, position|
        row = import_message!(wire, native_position: position_base + position)
        message = row if wire == snapshot.dig("status", "message")
      end
      message ||= import_message!(snapshot.dig("status", "message")) if snapshot.dig("status", "message")
      Array(snapshot["artifacts"]).each_with_index { |wire, position| import_artifact!(wire, native_position: position) }
      if snapshot.key?("artifacts")
        task.artifacts.where.not(native_artifact_id: snapshot["artifacts"].map { |wire| wire["artifactId"] }).destroy_all
      end
      status = snapshot.fetch("status")
      status_changed = status_changed?(status, observed_at: now)
      changed = before != native_base_digest || task.state != status["state"] || upstream_metadata != (snapshot["metadata"] || {})
      # A snapshot is a new base, never an invented native status/chunk. A2A
      # has no replay cursor; even the first subscribe has a send-window gap.
      if changed || status_changed
        task.events.create!(kind: "snapshot_boundary", state: status.fetch("state"), status_message_id: message&.message_id,
          settlement_evidence: status_changed, payload: translated_status(status, observed_at: status_changed ? now : task.status_at), created_at: now)
        attrs = { state: status.fetch("state"), status_message_id: message&.message_id, content_changed_at: now }
        attrs[:status_at] = now if status_changed
        task.update!(attrs)
        changed = true
      end
      semantic = snapshot.deep_dup
      semantic.fetch("status").delete("timestamp")
      update!(snapshot_digest: Digest::SHA256.hexdigest(RelayDelivery.canonical_json(semantic)),
        upstream_metadata: snapshot["metadata"] || {}, upstream_status_at: parse_timestamp(status["timestamp"]),
        changed_at: changed ? now : changed_at, gap: true)
    end

    def observe_native_message!(wire, now)
      raise InvalidSnapshot if task.terminal?
      A2a::NativeResult.validate_message!(wire)
      validate_message!(wire, expected_context: native_message_context)
      row = import_message!(wire)
      if row.previous_changes.any?
        # Lifecycle streams carry status/artifact deltas, not an invented
        # status for a standalone Message (§3.1.2). Readers need a new base.
        task.events.create!(kind: "snapshot_boundary", settlement_evidence: false, payload: { "taskId" => task.id, "contextId" => task.context_id }, created_at: now)
        task.update!(content_changed_at: now)
        update!(changed_at: now, snapshot_digest: nil, gap: true)
      end
    end

    def validate_native_delta!(wire)
      A2a::NativeResult.object!(wire)
      expected_context = native_context_id || native_message_context
      A2a::NativeResult.string!(wire["contextId"])
      raise InvalidSnapshot unless wire["taskId"] == native_task_id && wire["contextId"] == expected_context
      A2a::NativeResult.metadata!(wire)
      raise InvalidSnapshot if task.terminal?
    end

    def observe_native_status!(wire, now)
      validate_native_delta!(wire)
      status = wire["status"]
      A2a::NativeResult.validate_task!({ "id" => native_task_id, "status" => status }.tap { |snapshot| snapshot["contextId"] = native_context_id if native_context_id })
      message = status["message"]
      validate_message!(message, expected_context: native_message_context) if message
      row = import_message!(message) if message
      status_changed = status_changed?(status, observed_at: now)
      attrs = { state: status.fetch("state"), status_message_id: row&.message_id }
      attrs.merge!(status_at: now, content_changed_at: now) if status_changed
      task.update!(attrs)
      translated = translated_status(status, observed_at: status_changed ? now : task.status_at)
      translated["metadata"] = wire["metadata"].deep_dup if wire.key?("metadata")
      task.events.create!(kind: "status", state: task.state, status_message_id: task.status_message_id, settlement_evidence: status_changed,
        payload: translated, upstream_timestamp: status["timestamp"], created_at: now)
      update!(upstream_status_at: parse_timestamp(status["timestamp"]), changed_at: status_changed ? now : changed_at, snapshot_digest: nil)
    end

    def observe_native_artifact!(wire, now)
      validate_native_delta!(wire)
      %w[append lastChunk].each do |key|
        raise InvalidSnapshot if wire.key?(key) && ![ true, false ].include?(wire[key])
      end
      artifact = wire["artifact"]
      A2a::NativeResult.object!(artifact)
      # An empty final append is still an observed ordered event (§4.2.2).
      if artifact["parts"] == [] && wire["append"] == true && wire["lastChunk"] == true
        A2a::NativeResult.validate_artifact!(artifact.merge("parts" => [ { "text" => "" } ]))
      else
        A2a::NativeResult.validate_artifact!(artifact)
      end
      row = task.artifacts.find_by(native_artifact_id: artifact.fetch("artifactId"))
      raise InvalidSnapshot if wire["append"] == true && row.nil?
      assembled = artifact.deep_dup
      if wire["append"] == true
        assembled["parts"] = row.parts.deep_dup + artifact.fetch("parts")
        %w[name description metadata extensions].each { |key| assembled[key] = row.public_send(key) unless artifact.key?(key) }
      end
      import_artifact!(assembled)
      translated = wire.deep_dup.merge("taskId" => task.id, "contextId" => task.context_id)
      task.events.create!(kind: "artifact", payload: translated, created_at: now)
      task.update!(content_changed_at: now)
      update!(changed_at: now, snapshot_digest: nil)
    end

    def native_base_digest
      Digest::SHA256.hexdigest(RelayDelivery.canonical_json([
        task.messages.order(:message_id).map { |row| row.attributes.except("updated_at", "created_at") },
        task.artifacts.order(:artifact_id).map { |row| row.attributes.except("updated_at", "created_at") }
      ]))
    end

    def check_native_task_budget!
      size = task.messages.sum { |row| row.attributes.to_json.bytesize } +
        task.artifacts.sum { |row| row.attributes.to_json.bytesize } + upstream_metadata.to_json.bytesize
      raise InvalidSnapshot if size > TASK_LIMIT
    end
  end
end
