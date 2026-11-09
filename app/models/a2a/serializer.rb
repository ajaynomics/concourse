module A2a
  # ProtoJSON: camelCase names, enum strings as declared, timestamps in UTC
  # with a Z suffix (§5.5, §5.6). Omitted fields are omitted, not null:
  # ListTasks must drop artifacts entirely when includeArtifacts is false
  # (§3.1.4), and historyLength 0 omits history (§3.2.4).
  module Serializer
    # Internal worker transport budgets, not A2A protocol limits.
    MAX_INBOX_TASK_BYTES = 384 * 1024
    MAX_INBOX_PAGE_BYTES = 768 * 1024
    # Covers the envelope, cursor and content-free diagnostics for at most 100 rows.
    INBOX_ENVELOPE_BYTES = 32 * 1024

    # Fixed SQLite expressions: BLOB length measures UTF-8 bytes, not characters.
    # Only aggregate sizes/counts leave these Task-scoped child queries. Counting
    # all persisted ID alternatives conservatively covers wire ID precedence.
    INBOX_MESSAGE_BYTES_SQL = <<~SQL.squish.freeze
      COALESCE(SUM(
        COALESCE(LENGTH(CAST(messages.parts AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(messages.metadata AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(messages.extensions AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(messages.reference_task_ids AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(messages.message_id AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(messages.client_message_id AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(messages.native_message_id AS BLOB)), 0)
      ), 0) + COUNT(*) * 128
    SQL
    INBOX_ARTIFACT_BYTES_SQL = <<~SQL.squish.freeze
      COALESCE(SUM(
        COALESCE(LENGTH(CAST(artifacts.parts AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(artifacts.metadata AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(artifacts.extensions AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(artifacts.name AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(artifacts.description AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(artifacts.artifact_id AS BLOB)), 0) +
        COALESCE(LENGTH(CAST(artifacts.native_artifact_id AS BLOB)), 0)
      ), 0) + COUNT(*) * 128
    SQL

    module_function

    # A2A §4.1.1: return full snapshots or omit the entire Task, never truncate
    # history/artifacts or invent a work outcome. Visibility is the caller's duty.
    # A processed cursor skips diagnosed Tasks without acknowledging their work.
    def mailbox_page(records, next_page_token:, page_size:)
      tasks = []
      blocked_tasks = []
      page_bytes = INBOX_ENVELOPE_BYTES
      last_processed = nil

      records.each do |record|
        message_bytes, message_count = record.messages.pick(Arel.sql(INBOX_MESSAGE_BYTES_SQL), Arel.sql("COUNT(*)"))
        # The selected Task already holds context_id; each history Message repeats
        # it (§4.1.1, §4.1.2), in addition to the base Task's context occurrence.
        estimate = message_bytes.to_i + record.context_id.bytesize * (message_count.to_i + 1) +
          record.artifacts.pick(Arel.sql(INBOX_ARTIFACT_BYTES_SQL)).to_i
        payload = if estimate <= MAX_INBOX_TASK_BYTES
          task(record, artifacts: :include, caller: true)
        end
        # Rails' actual JSON encoding also counts escaping and status.message's
        # repeated history content, neither of which a storage estimate can prove.
        bytes = payload && ActiveSupport::JSON.encode(payload).bytesize
        if !bytes || bytes > MAX_INBOX_TASK_BYTES
          blocked_tasks << { "taskId" => record.id, "code" => "INBOX_TASK_TOO_LARGE" }
        elsif page_bytes + bytes + 1 > MAX_INBOX_PAGE_BYTES
          next_page_token = yield last_processed
          break
        else
          tasks << payload
          page_bytes += bytes + 1
        end
        last_processed = record
      end

      { "tasks" => tasks, "blockedTasks" => blocked_tasks,
        "nextPageToken" => next_page_token, "pageSize" => page_size }
    end

    def task(record, history_length: nil, artifacts: :if_present, caller: false, recipient: false)
      label = caller ? caller_label(record) : nil
      reply_bindings = TaskEvent.reply_bindings(record)
      payload = {
        "id" => record.id,
        "contextId" => record.context_id,
        "status" => status(record, caller: label, reply_bindings: reply_bindings)
      }
      payload.delete("contextId") if record.relay_task && record.relay_task.native_context_id.nil?
      metadata = relay_metadata(record)
      metadata["concourse.output"] = current_output(record) if Concourse.v3? && record.inbox?
      input = record.latest_caller_input
      metadata["concourse.caller_input"] = input if input
      metadata["concourse.caller"] = label if label
      metadata["concourse.recipient"] = agent_label(record.recipient_agent) if recipient && record.recipient_agent
      parties = participants(record)
      metadata["concourse.participants"] = parties if parties
      payload["metadata"] = metadata if metadata.any?
      case artifacts
      when :include
        payload["artifacts"] = artifacts_for(record, reply_bindings: reply_bindings)
      when :if_present
        listed = artifacts_for(record, reply_bindings: reply_bindings)
        payload["artifacts"] = listed if listed.any?
      end
      unless history_length == 0
        payload["history"] = history(record, history_length, caller: label, reply_bindings: reply_bindings)
      end
      payload
    end

    def message(record, caller: nil, reply_bindings: nil)
      payload = {
        "messageId" => record.wire_message_id,
        "contextId" => record.task.context_id,
        "taskId" => record.task_id,
        "role" => record.role,
        "parts" => Array(record.parts).map { |part| part_hash(part) }
      }
      payload.delete("taskId") if record.native_message_id.present? && record.native_task_id.nil?
      payload.delete("contextId") if record.role == "ROLE_USER" && record.native_message_id.present? && record.native_context_id.nil?
      metadata = record.metadata.is_a?(Hash) ? record.metadata.dup : {}
      metadata.delete("concourse.reply_to")
      metadata.delete("concourse.send_receipt")
      if Concourse.v3?
        metadata.reject! { |key, _| key.to_s.in?(%w[concourse.participants concourse.sender]) }
        identity = sender(record)
        metadata["concourse.sender"] = identity if identity
        if record.role == "ROLE_AGENT" && record.sender_agent_id == record.task.recipient_agent_id
          binding = (reply_bindings || TaskEvent.reply_bindings(record.task)).fetch("messages")[record.wire_message_id]
          metadata["concourse.reply_to"] = binding if binding
        end
      end
      metadata["concourse.caller"] = caller if caller && record.role == "ROLE_USER"
      payload["metadata"] = metadata if metadata.present?
      payload["extensions"] = record.extensions if record.extensions.present?
      payload["referenceTaskIds"] = record.reference_task_ids if record.reference_task_ids.present?
      payload
    end

    def artifact(record, reply_bindings: nil)
      payload = {
        "artifactId" => record.native_artifact_id.presence || record.artifact_id,
        "parts" => Array(record.parts).map { |part| part_hash(part) }
      }
      payload["name"] = record.name if record.name.present?
      payload["description"] = record.description if record.description.present?
      metadata = record.metadata.is_a?(Hash) ? record.metadata.dup : {}
      metadata.delete("concourse.reply_to")
      metadata.delete("concourse.send_receipt")
      binding = (reply_bindings || TaskEvent.reply_bindings(record.task)).fetch("artifacts")[record.artifact_id]
      metadata["concourse.reply_to"] = binding if binding
      payload["metadata"] = metadata if metadata.present?
      payload["extensions"] = record.extensions if record.extensions.present?
      payload
    end

    def status(record, caller: nil, reply_bindings: nil)
      payload = {
        "state" => record.state,
        "timestamp" => timestamp(record.status_at)
      }
      status_message = record.status_message
      payload["message"] = message(status_message, caller: caller, reply_bindings: reply_bindings) if status_message
      payload
    end

    # A2A §4.1.1 snapshots retain previous content. The v3 observer names only
    # outputs in the latest recorded status change, including same-state settlement.
    # No new RPC, content rewriting or caller-supplied authority is involved.
    def current_output(record)
      current, previous = record.events.where.not(state: nil).order(id: :desc).limit(2).to_a
      message_ids = []
      artifact_ids = []
      if current && current.status_at.utc.iso8601(6) == record.status_at.utc.iso8601(6) && current.state == record.state
        if output = current.reply_output(task: record)
          message_ids = output.fetch("messageIds").dup
          artifact_ids = output.fetch("artifactIds").dup
          binding = current.reply_metadata(task: record)
        else
          if current.status_message_id.present? && current.status_message_id != previous&.status_message_id
            message_ids << current.status_message.wire_message_id
          end
          artifact_ids = record.events.where(id: ((previous&.id || 0) + 1)...current.id)
            .where.not(artifact_id: nil).order(:id).pluck(:artifact_id)
        end
      end
      if record.state == "TASK_STATE_INPUT_REQUIRED" && current
        # Restating the old question must not re-open it after accepted input.
        origin = current.status_message_id && record.events.where(status_message_id: current.status_message_id)
          .where.not(state: nil).minimum(:id)
        if record.events.where(kind: "caller_input").where(id: ((origin || current.id) + 1)..).exists?
          message_ids = []
          artifact_ids = []
        end
      end
      output = { "statusTimestamp" => timestamp(record.status_at), "messageIds" => message_ids, "artifactIds" => artifact_ids }
      if binding
        output["callerInput"] = binding.fetch("callerInput")
        output["statusEventId"] = binding.fetch("statusEventId")
      end
      output
    end

    def relay_metadata(record)
      return {} if record.inbox?

      relay = record.relay_task
      metadata = (relay&.upstream_metadata || {}).reject { |key, _| key.start_with?("concourse.") }
      metadata["concourse.route"] = record.execution_route
      delivery = record.relay_deliveries.where(operation: "SendMessage").order(created_at: :desc, id: :desc).first
      metadata["concourse.delivery"] = delivery&.outcome || (record.held? ? "unconfirmed" : "accepted")
      if relay
        metadata["concourse.observedAt"] = timestamp(relay.observed_at) if relay.observed_at
        metadata["concourse.upstreamStatusAt"] = timestamp(relay.upstream_status_at) if relay.upstream_status_at
        metadata["concourse.stale"] = relay.observation_stale?
        metadata["concourse.gap"] = relay.gap
      end
      cancellation = record.relay_deliveries.where(operation: "CancelTask", phase: %w[reserved sending held]).order(created_at: :desc).first
      metadata["concourse.cancellation"] = cancellation.phase == "held" ? "unconfirmed" : "pending" if cancellation
      metadata
    end

    def timestamp(time)
      time.utc.iso8601(3)
    end

    def history(record, history_length, caller: nil, reply_bindings: nil)
      # Native array order is executor evidence (§4.1.1), not local import time.
      order = { created_at: :desc, message_id: :desc }
      order = { native_position: :desc }.merge(order) if record.relay_task
      scope = record.messages.order(order)
      scope = scope.limit(history_length) if history_length
      scope.reverse.map { |item| message(item, caller: caller, reply_bindings: reply_bindings) }
    end

    # A2A §3.2.5, §4.1.1/§4.1.4 metadata, scoped by the existing lookup
    # (§13.1). These are recorded inbox identities, not upstream author claims.
    def participants(record)
      return unless Concourse.v3? && record.inbox?
      caller = participant(record, record.caller_agent)
      recipient = participant(record, record.recipient_agent)
      return unless caller && recipient && record.messages.where(role: "ROLE_USER", sender_agent_id: record.caller_agent_id).exists?

      { "version" => 1, "organizationId" => record.organization_id, "organization" => record.organization.slug,
        "caller" => caller, "recipient" => recipient }
    end

    def sender(record)
      task = record.task
      return unless Concourse.v3? && task.inbox?
      agent = case record.role
      when "ROLE_USER" then task.caller_agent
      when "ROLE_AGENT" then task.recipient_agent
      end
      return unless agent && record.sender_agent_id == agent.id
      identity = participant(task, agent)
      return unless identity

      identity.merge("version" => 1, "organizationId" => task.organization_id, "organization" => task.organization.slug)
    end

    def participant(task, agent)
      return unless agent && agent.organization_id == task.organization_id && agent.qualified_handle.present?

      { "agentId" => agent.id, "handle" => agent.qualified_handle }
    end


    def caller_label(record)
      agent = record.caller_agent
      return unless agent

      agent_label(agent)
    end

    def agent_label(agent)
      agent.qualified_handle || "#{agent.owner.handle}/(unnamed)"
    end

    def artifacts_for(record, reply_bindings: nil)
      order = record.relay_task ? [ :native_position, :created_at, :artifact_id ] : [ :created_at, :artifact_id ]
      record.artifacts.order(*order).map { |item| artifact(item, reply_bindings: reply_bindings) }
    end

    # raw is ProtoJSON base64 (Part.raw, §5.6), including file parts an agent
    # attaches. Inbound SendMessage still rejects raw and url parts; that is
    # a content-type limit on what a caller may send, not on artifacts.
    def part_hash(part)
      hash = part.to_h.stringify_keys
      out = {}
      %w[text raw url filename mediaType].each do |key|
        value = hash[key]
        out[key] = value if value.is_a?(String)
      end
      out["data"] = hash["data"] if hash.key?("data")
      out["metadata"] = hash["metadata"] if hash["metadata"].is_a?(Hash) && hash["metadata"].any?
      out
    end
  end
end
