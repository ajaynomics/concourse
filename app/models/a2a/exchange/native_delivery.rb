module A2a::Exchange::NativeDelivery
  extend ActiveSupport::Concern

  class_methods do
    # Recovery can only fence or expose uncertainty. It never selects a route,
    # obtains credentials, acquires a network slot or dispatches (§3.3.1).
    def recover_delivery!(delivery)
      new(delivery.caller_agent).send(:recover_receipt, delivery)
    end
  end

  class NativeRejection < A2a::Error
    def initialize(payload)
      @payload = payload
      super(:internal)
    end

    def to_h
      @payload
    end
  end

  private

  # Selection and reservation share the recipient lock. A duplicate never
  # selects an executor again, even after registration or a switch change (§3.3.1).
  def deliver(recipient, raw_message, configuration, metadata: {}, via: nil)
    reject_push_config!(configuration)
    message = normalized_delivery_message(raw_message, via: via)
    metadata = metadata_of("metadata" => hash(metadata))
    modes = string_list(configuration, "acceptedOutputModes", "accepted_output_modes")
    digest = Digest::SHA256.hexdigest(RelayDelivery.canonical_json(
      { "message" => message, "metadata" => metadata, "acceptedOutputModes" => modes }))
    legacy = inbox_answer = nil
    new_delivery = false
    recipient.with_lock do
      assert_participants!(recipient)
      legacy = Message.find_by(sender_agent: @agent, client_message_id: message.fetch("messageId")) # tenancy-ok: caller's own legacy dedupe, checked through visibility next
      legacy_task = idempotent_task(legacy, recipient) if legacy
      previous = RelayDelivery.where(caller_agent_id: @agent.id, message_id_digest: Digest::SHA256.hexdigest(message.fetch("messageId"))).first # tenancy-ok: caller's content-free fence survives moves
      if previous
        @delivery = RelayDelivery.reserve!(caller: @agent, recipient: recipient, message: message,
          execution_route: previous.execution_route, request_digest: digest)
      else
        task = legacy_task || (continue(recipient, message["taskId"], message["contextId"]) if message["taskId"])
        route = task ? (task.inbox? ? "inbox" : "native") : (recipient.native_delivery_available? ? "native" : "inbox")
        mapping = task&.relay_task
        raise A2a::RelayError.new("RELAY_DELIVERY_UNCONFIRMED", task_id: task.id) if task&.held? && !mapping
        ensure_native_mutation_available!(task) if route == "native" && task
        snapshot = route == "native" ? (mapping&.route_snapshot || recipient.native_route_snapshot) : nil
        validate_delivery_references!(message, recipient, snapshot: snapshot)
        @delivery = RelayDelivery.reserve!(caller: @agent, recipient: recipient, message: message,
          task: task, execution_route: route, route_snapshot: snapshot, request_digest: digest)
        new_delivery = @delivery.previously_new_record?
        @mapping_fence = mapping&.fence
        @after_sequence = task&.events&.maximum(:id) || 0
        if new_delivery && route == "native"
          @context = context_for_delivery(@delivery, message, task)
          @delivery.update!(request_payload: @delivery.request_payload.merge("_relayPublicContextId" => @context.public_context_id))
        end
        if new_delivery && legacy
          @delivery.accept!(task: task, result: inbox_receipt(task))
        end
        # Inbox delivery is entirely local. Commit its receipt, task and message
        # together: a crash, restart or dropped request between them must not
        # leave a reserved receipt that turns every same-messageId retry PENDING.
        inbox_answer = deliver_inbox if new_delivery && !legacy && route == "inbox"
      end
    end
    return inbox_answer if inbox_answer
    return replay_delivery if legacy || !new_delivery
    return deliver_inbox if @delivery.execution_route == "inbox"

    dispatch_native(metadata: metadata, modes: modes)
  rescue RelayDelivery::Mismatch
    raise A2a::Error.new(:invalid_params)
  rescue RelayDelivery::Expired
    raise A2a::RelayError.new("RELAY_RECORD_EXPIRED")
  rescue RelayDelivery::Pending, RelayDelivery::LostFence
    raise delivery_error("RELAY_DELIVERY_PENDING")
  rescue RelayDelivery::Busy
    raise delivery_error("RELAY_MUTATION_BUSY")
  rescue Agent::Unadmitted
    # A rolled-back reservation has no row to fence.
    @delivery.expire! if @delivery&.persisted?
    raise A2a::Error.new(:task_not_found)
  end

  def normalized_delivery_message(raw, via:)
    raw = hash(raw)
    raise A2a::Error.new(:invalid_params) unless raw["role"] == "ROLE_USER"
    message = { "messageId" => required_string(raw, "messageId", "message_id"),
      "role" => "ROLE_USER", "parts" => normalize_parts(raw["parts"]) }
    %w[taskId contextId].each do |key|
      snake = key == "taskId" ? "task_id" : "context_id"
      value = field(raw, key, snake)
      raise A2a::Error.new(:invalid_params) if value && (!value.is_a?(String) || value.blank?)
      message[key] = value if value
    end
    message["metadata"] = metadata_of(raw)
    raise A2a::Error.new(:invalid_params) unless via.nil? || via == "owner"
    message["metadata"]["concourse.via"] = via if via
    message["extensions"] = string_list(raw, "extensions")
    message["referenceTaskIds"] = string_list(raw, "referenceTaskIds", "reference_task_ids")
    raise A2a::Error.new(:invalid_params) if message.to_json.bytesize > A2a::NativeTransport::REQUEST_LIMIT
    message
  end

  def validate_delivery_references!(message, recipient, snapshot:)
    Array(message["referenceTaskIds"]).each do |id|
      referenced = locate(id)
      next unless snapshot
      native = referenced.relay_task
      unless referenced.caller_agent_id == @agent.id && referenced.recipient_agent_id == recipient.id &&
          native && native.route_snapshot == snapshot.stringify_keys.reverse_merge("native_streaming" => false)
        raise A2a::Error.new(:invalid_params)
      end
    end
  end

  def context_for_delivery(delivery, message, task)
    if task
      return RelayContext.map!(caller: @agent, recipient: delivery.recipient_agent, generation: delivery.generation,
        public_context_id: task.context_id, native_context_id: task.relay_task.native_context_id)
    end
    context = RelayContext.map!(caller: @agent, recipient: delivery.recipient_agent, generation: delivery.generation,
      public_context_id: message["contextId"])
    context.bind_native!(SecureRandom.uuid) if message["contextId"] && context.native_context_id.nil?
    context
  end

  def replay_delivery
    result = @delivery.replay!(allow_held: true)
    if @delivery.phase == "held" && @delivery.task_id && @delivery.operation == "SendMessage"
      task = locate(@delivery.task_id)
      raise delivery_error("RELAY_DELIVERY_UNCONFIRMED") unless task.held?
      return [ task, nil ]
    end
    raise delivery_error("RELAY_DELIVERY_PENDING") unless result.is_a?(Hash)
    raise NativeRejection.new(result.fetch("error")) if result["error"]
    return [ A2a::DirectMessage.new(payload: result.fetch("message")), nil ] if result["message"]

    @after_sequence = result["afterSequence"] || 0
    task = locate(@delivery.public_task_id)
    [ task, (task.messages.where(client_message_id: @delivery.request_payload["messageId"]).pick(:created_at) if @delivery.task_id) ]
  end

  def deliver_inbox
    task = recorded = answer = nil
    RelayDelivery.transaction do
      @delivery.lock!
      raise RelayDelivery::Pending unless @delivery.phase == "reserved"
      assert_delivery_participants!
      task = @delivery.task || Task.create!(id: @delivery.reserved_task_id, organization: @delivery.organization,
        caller_agent: @agent, recipient_agent: @delivery.recipient_agent,
        context_id: @delivery.request_payload["contextId"], state: "TASK_STATE_SUBMITTED")
      task.lock!
      task.ensure_inbox!
      message = @delivery.request_payload
      recorded = Message.record!(task: task, role: "ROLE_USER", sender: @agent,
        parts: message.fetch("parts"), metadata: message["metadata"], message_id: message.fetch("messageId"),
        extensions: message["extensions"], reference_task_ids: message["referenceTaskIds"])
      answer = A2a::Inbound.deliver(task)
      if answer.is_a?(A2a::DirectMessage)
        @delivery.accept!(result: { "message" => answer.to_h })
      else
        @delivery.accept!(task: task, result: inbox_receipt(task, recorded: recorded))
      end
    end
    return [ answer, nil ] if answer.is_a?(A2a::DirectMessage)

    [ task.reload, (recorded.created_at if @delivery.request_payload["taskId"]) ]
  end

  # Replay loads an inbox task by the receipt's public_task_id, so the receipt
  # keeps a reference, not a snapshot that grows with history past
  # RelayDelivery::PAYLOAD_LIMIT. Older receipts holding a full snapshot replay
  # the same way; their copy is never read.
  def inbox_receipt(task, recorded: nil)
    result = { "task" => { "id" => task.id } }
    # Captured under the delivery/Task transaction, after the exact Message's
    # after_create event. A2A §3.3.1 dedupe preserves this operation, not latest input.
    if input = recorded&.recorded_caller_input
      result["callerInputMessageId"] = recorded.message_id
      result["sendReceipt"] = { "version" => 1, "callerInput" => input }
    end
    result
  end

  def dispatch_native(metadata:, modes:)
    holder = SecureRandom.uuid
    slot = nil
    rpc_id = SecureRandom.uuid
    body = native_request(rpc_id, metadata: metadata, modes: modes)
    # Oversized requests are invalid before any upstream/token I/O (§13.1).
    if body.bytesize > A2a::NativeTransport::REQUEST_LIMIT
      return reject_reserved_delivery("RELAY_REQUEST_LIMIT")
    end
    assert_delivery_participants!
    return reject_reserved_delivery("RELAY_OUTBOUND_DISABLED") unless Agent.native_outbound_available?
    token = without_database_connection { Ajent::RelayToken.fetch(resource: @delivery.resource) }
    slot = RelayNetworkSlot.acquire(kind: :dispatch, organization: @delivery.organization, holder: holder)
    return reject_reserved_delivery("RELAY_CAPACITY") unless slot

    RelayDelivery.transaction do
      @delivery.lock!
      assert_delivery_participants!
      ensure_native_mutation_available!(@delivery.task, current_delivery: @delivery) if @delivery.task
      raise RelayDelivery::LostFence unless slot.held_by?(holder)
      return reject_reserved_delivery("RELAY_OUTBOUND_DISABLED") unless Agent.native_outbound_available?
      @delivery.start_sending!(holder: holder, deadline_at: 10.seconds.from_now)
    end
    fence = @delivery.fence
    @after_sequence = @delivery.after_sequence if @delivery.task_id
    assert_delivery_participants!
    unless Agent.native_outbound_available?
      return reject_sent_delivery("RELAY_OUTBOUND_DISABLED", holder, fence)
    end
    attribution = { organization: @delivery.organization.slug, recipient: @delivery.recipient_agent.qualified_handle }
    headers = { "Concourse-Caller" => @agent.qualified_handle, "Concourse-Task" => @delivery.reserved_task_id,
      "Concourse-Delivery" => @delivery.id }
    headers["Concourse-Via"] = "owner" if @delivery.request_payload&.dig("metadata", "concourse.via") == "owner"
    admission = -> { assert_connection_admission!(slot, holder, fence) }
    admission.call
    response = without_database_connection do
      A2a::NativeTransport.new(organization_id: @delivery.organization_id, recipient_id: @delivery.recipient_agent_id,
        attribution: attribution).post(url: @delivery.endpoint_url, resource: @delivery.resource, body: body, token: token,
          headers: headers, admission: admission)
    end
    if [ 401, 403 ].include?(response.status)
      return reject_sent_delivery("RELAY_NATIVE_AUTH", holder, fence)
    end
    result = parse_native_response(response, rpc_id)
    if result.error
      @delivery.reject!(result: { "error" => result.error }, holder: holder, fence: fence)
      assert_delivery_participants!
      raise NativeRejection.new(result.error)
    end
    record_native_acceptance(result, holder, fence)
  rescue Ajent::RelayToken::Error
    reject_reserved_delivery("RELAY_TOKEN_FAILURE")
  rescue A2a::NativeTransport::ConfigurationError, A2a::NativeTransport::CapacityExceeded => error
    reason = error.is_a?(A2a::NativeTransport::CapacityExceeded) ? "RELAY_CAPACITY" : "RELAY_CONFIGURATION"
    @delivery.phase == "reserved" ? reject_reserved_delivery(reason) : reject_sent_delivery(reason, holder, fence)
  rescue A2a::NativeTransport::Unavailable => error
    evidence = error.evidence.to_s
    if @delivery.operation == "SendMessage" && @delivery.task_id.nil? && error.certainly_unsent? && RelayDelivery::UNSENT_EVIDENCE.include?(evidence)
      RelayDelivery.transaction do
        @delivery.fallback_to_inbox!(holder: holder, fence: fence, evidence: evidence)
        return deliver_inbox
      end
    end
    hold_native_delivery(holder, fence)
  rescue A2a::NativeTransport::Unconfirmed, A2a::NativeResult::Invalid, RelayTask::InvalidSnapshot,
      ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    hold_native_delivery(holder, fence)
  rescue Agent::Unadmitted
    @delivery.expire! if @delivery
    raise A2a::Error.new(:task_not_found)
  ensure
    slot&.release(holder)
  end

  def native_request(rpc_id, metadata:, modes:)
    params = if @delivery.operation == "CancelTask"
      { "id" => @delivery.task.relay_task.native_task_id }
    else
      message = @delivery.request_payload.deep_dup
      message.delete("_relayPublicContextId")
      message["metadata"] = message["metadata"].reject { |key, _| key.start_with?("concourse.") } if message.key?("metadata")
      mapping = @delivery.task&.relay_task
      message.delete("taskId")
      message["taskId"] = mapping.native_task_id if mapping
      message.delete("contextId")
      context_id = mapping ? mapping.native_context_id : @context.native_context_id
      message["contextId"] = context_id if context_id
      message["referenceTaskIds"] = Array(message["referenceTaskIds"]).map { |id| locate(id).relay_task.native_task_id }
      { "message" => message, "configuration" => { "returnImmediately" => true }.tap { |config| config["acceptedOutputModes"] = modes if modes.any? } }
    end
    params["metadata"] = metadata if metadata.any?
    params["tenant"] = @delivery.tenant if @delivery.tenant.present?
    JSON.generate(jsonrpc: "2.0", id: rpc_id, method: @delivery.operation, params: params)
  end

  def parse_native_response(response, rpc_id)
    raise A2a::NativeResult::Invalid unless response.headers["content-type"].to_s.split(";").first.to_s.strip.downcase == "application/json"
    if @delivery.operation == "CancelTask"
      # CancelTask's result is a Task, not the SendMessageResponse union (§3.1.5).
      result = A2a::NativeResult.parse_task(response.body, rpc_id: rpc_id)
    else
      result = A2a::NativeResult.parse(response.body, rpc_id: rpc_id)
    end
    # A matching refusal is preserved regardless of HTTP status. An arbitrary
    # gateway/proxy status is never evidence of non-delivery.
    raise A2a::NativeResult::Invalid unless result.error || response.status == 200
    result
  rescue JSON::ParserError, TypeError
    raise A2a::NativeResult::Invalid
  end

  def record_native_acceptance(result, holder, fence)
    answer = nil
    @delivery.recipient_agent.with_lock do
      @delivery.lock!
      assert_delivery_fence!(holder, fence)
      assert_delivery_participants!
      if result.task
        answer = import_native_task(result.task)
        answer.confirm_native_observation!(delivery: @delivery, holder: holder, fence: fence) if answer.held?
        @delivery.accept!(task: answer, holder: holder, fence: fence,
          result: { "task" => A2a::Serializer.task(answer), "afterSequence" => @after_sequence })
      else
        translated = translate_direct_message(result.message)
        associated = @delivery.task
        seed_native_user_message(associated, associated.relay_task) if associated&.native? && @delivery.operation == "SendMessage"
        associated&.mark_content_changed!
        @delivery.accept!(task: associated, holder: holder, fence: fence, result: { "message" => translated })
        associated.retire_message_tracking!(delivery: @delivery, holder: holder, fence: fence) if associated&.held? && !translated.key?("taskId")
        @delivery.reload
        answer = A2a::DirectMessage.new(payload: translated)
      end
    end
    assert_delivery_participants!
    answer.relay_task.enqueue_follow if answer.is_a?(Task) && answer.relay_task
    [ answer, nil ]
  end

  def import_native_task(snapshot)
    mapping = @delivery.organization.relay_tasks.where(recipient_agent_id: @delivery.recipient_agent_id,
      generation: @delivery.generation, native_task_id: snapshot.fetch("id")).first
    existing_task = @delivery.task
    existing_mapping = mapping.present?
    if mapping
      unless mapping.caller_agent_id == @agent.id && mapping.native_context_id == snapshot["contextId"] &&
          mapping.route_snapshot == @delivery.route_snapshot.slice(*RelayTask::SNAPSHOT_FIELDS) &&
          (!existing_task || mapping.task_id == existing_task.id)
        raise RelayTask::InvalidSnapshot
      end
      task = locate(mapping.task_id)
      if @delivery.request_payload["contextId"] && task.context_id != @delivery.request_payload["contextId"]
        raise RelayTask::InvalidSnapshot
      end
      @context = RelayContext.map!(caller: @agent, recipient: @delivery.recipient_agent, generation: @delivery.generation,
        public_context_id: task.context_id, native_context_id: snapshot["contextId"])
    else
      if existing_task && (!existing_task.held? || existing_task.id != @delivery.reserved_task_id)
        raise RelayTask::InvalidSnapshot
      end
      @context = context_for_native_result(snapshot["contextId"])
      if existing_task
        raise RelayTask::InvalidSnapshot unless existing_task.context_id == @context.public_context_id
        task = existing_task
      else
        task = Task.create!(id: @delivery.reserved_task_id, organization: @delivery.organization,
          caller_agent: @agent, recipient_agent: @delivery.recipient_agent,
          context_id: @context.public_context_id, execution_route: "native", state: "TASK_STATE_SUBMITTED")
      end
      mapping = RelayTask.create!(task: task, organization: @delivery.organization,
        caller_agent: @agent, recipient_agent: @delivery.recipient_agent,
        **@delivery.route_snapshot.slice(*RelayTask::SNAPSHOT_FIELDS).symbolize_keys,
        native_task_id: snapshot.fetch("id"), native_context_id: snapshot["contextId"], next_follow_at: Time.current, gap: true)
    end
    task.lock!
    mapping.lock!
    if (existing_task && existing_mapping && @mapping_fence != mapping.fence) || (mapping.lease_expires_at && mapping.lease_expires_at > Time.current)
      raise RelayTask::InvalidSnapshot
    end
    @after_sequence ||= task.events.maximum(:id) || 0
    old_event = task.events.where(kind: %w[status snapshot_boundary], settlement_evidence: true).order(:id).last
    old_status = old_event&.payload&.dig("status")&.deep_dup
    if old_status
      old_event.upstream_timestamp ? old_status["timestamp"] = old_event.upstream_timestamp : old_status.delete("timestamp")
    end
    # Attach before import so ROLE_USER echoes are evidence-bound to a request.
    @delivery.update!(task: task, public_task_id: task.id)
    seed_native_user_message(task, mapping) if @delivery.operation == "SendMessage"
    mapping.import_snapshot!(snapshot)
    # A repeated old interruption plus a newly echoed user message is not
    # settlement of that input (§3.2.2). Persist a sequence, not a clock guess.
    if existing_task && same_native_status?(old_status, snapshot["status"], mapping)
      @after_sequence = task.events.maximum(:id) || @after_sequence
    end
    task.reload
  end

  def same_native_status?(old, incoming, mapping)
    return false unless old
    old = old.deep_dup
    message = old["message"]
    if message
      message["taskId"] = mapping.native_task_id if message["taskId"]
      message["contextId"] = mapping.native_context_id
      message["referenceTaskIds"] = Array(message["referenceTaskIds"]).map { |id| locate(id).relay_task.native_task_id } if message.key?("referenceTaskIds")
    end
    old == incoming
  end

  def seed_native_user_message(task, mapping = nil)
    request = @delivery.request_payload
    row = task.messages.find_or_initialize_by(role: "ROLE_USER", native_message_id: request.fetch("messageId"))
    if row.persisted?
      raise RelayTask::InvalidSnapshot unless row.parts == request["parts"] && row.sender_agent_id == @agent.id
      return row
    end
    row.assign_attributes(sender_agent: @agent, client_message_id: request.fetch("messageId"), created_at: @delivery.created_at,
      parts: request.fetch("parts"), metadata: request["metadata"] || {}, extensions: request["extensions"] || [],
      reference_task_ids: request["referenceTaskIds"] || [], native_task_id: mapping&.native_task_id,
      native_context_id: mapping&.native_context_id, native_position: task.messages.maximum(:native_position).to_i + 1,
      native_after_sequence: request["taskId"] ? @delivery.after_sequence : nil)
    row.save!
    row
  end

  def context_for_native_result(native_id)
    return @context unless native_id
    if @context.native_context_id
      raise RelayTask::InvalidSnapshot unless @context.native_context_id == native_id
      return @context
    end
    existing = @delivery.organization.relay_contexts.where(caller_agent_id: @agent.id,
      recipient_agent_id: @delivery.recipient_agent_id, generation: @delivery.generation, native_context_id: native_id).first
    return existing if existing
    @context.bind_native!(native_id)
  end

  def translate_direct_message(raw)
    raise RelayTask::InvalidSnapshot unless raw["role"] == "ROLE_AGENT"
    mapping = @delivery.task&.relay_task
    if raw["taskId"]
      raise RelayTask::InvalidSnapshot unless mapping && raw["taskId"] == mapping.native_task_id
    end
    if mapping
      context = RelayContext.map!(caller: @agent, recipient: @delivery.recipient_agent, generation: @delivery.generation,
        public_context_id: mapping.task.context_id, native_context_id: mapping.native_context_id || raw["contextId"])
      raise RelayTask::InvalidSnapshot unless raw["contextId"] == context.native_context_id
      public_context = mapping.task.context_id
    else
      public_context = context_for_native_result(raw.fetch("contextId")).public_context_id
    end
    translated = raw.deep_dup
    translated["metadata"] = translated["metadata"].reject { |key, _| key.start_with?("concourse.") } if translated.key?("metadata")
    translated["taskId"] = mapping.task_id if raw["taskId"]
    translated["contextId"] = public_context
    translated["referenceTaskIds"] = Array(raw["referenceTaskIds"]).map do |native_id|
      reference = @delivery.organization.relay_tasks.where(caller_agent_id: @agent.id,
        recipient_agent_id: @delivery.recipient_agent_id, generation: @delivery.generation, native_task_id: native_id).first
      raise RelayTask::InvalidSnapshot unless reference && reference.route_snapshot == @delivery.route_snapshot.slice(*RelayTask::SNAPSHOT_FIELDS)
      locate(reference.task_id).id
    end if raw.key?("referenceTaskIds")
    translated
  end

  def recover_receipt(delivery)
    @delivery = delivery
    delivery.with_lock do
      return delivery if delivery.expired_at?
      assert_delivery_participants!
      delivery.recover_expired_reservation! if delivery.phase == "reserved"
      delivery.recover_expired_holder! if delivery.phase == "sending"
      if delivery.phase == "held" && delivery.execution_route == "native" && delivery.operation == "SendMessage" && delivery.task_id.nil?
        message = delivery.request_payload
        raise RelayDelivery::Mismatch unless message.is_a?(Hash)
        task = Task.create!(id: delivery.reserved_task_id, organization: delivery.organization,
          caller_agent: delivery.caller_agent, recipient_agent: delivery.recipient_agent,
          context_id: message["_relayPublicContextId"] || message["contextId"],
          execution_route: "held", state: "TASK_STATE_SUBMITTED")
        seed_native_user_message(task)
        task.update_columns(content_changed_at: delivery.content_changed_at)
        delivery.update!(task: task, public_task_id: task.id)
      end
    end
    delivery
  rescue Agent::Unadmitted
    delivery.expire!
    delivery
  end

  def hold_native_delivery(holder, fence)
    task = nil
    RelayDelivery.transaction do
      @delivery.lock!
      assert_delivery_fence!(holder, fence)
      assert_delivery_participants!
      task = @delivery.task
      unless task
        task = Task.create!(id: @delivery.reserved_task_id, organization: @delivery.organization,
          caller_agent: @agent, recipient_agent: @delivery.recipient_agent, execution_route: "held",
          context_id: @context.public_context_id, state: "TASK_STATE_SUBMITTED")
        seed_native_user_message(task)
        task.update_columns(content_changed_at: @delivery.content_changed_at)
      end
      @delivery.hold!(task: task, holder: holder, fence: fence)
    end
    raise delivery_error("RELAY_DELIVERY_UNCONFIRMED") unless task.held? && @delivery.operation == "SendMessage"
    [ task, nil ]
  end

  def reject_reserved_delivery(reason)
    exception = delivery_error(reason)
    @delivery.reject_reserved!(result: { "error" => exception.to_h })
    assert_delivery_participants!
    raise exception
  end

  def reject_sent_delivery(reason, holder, fence)
    exception = delivery_error(reason)
    @delivery.reject!(holder: holder, fence: fence, result: { "error" => exception.to_h })
    assert_delivery_participants!
    raise exception
  end

  def delivery_error(reason)
    A2a::RelayError.new(reason, task_id: @delivery&.public_task_id, delivery_id: @delivery&.id)
  end

  def assert_participants!(recipient)
    raise Agent::Unadmitted unless @agent.admitted? && recipient.admitted? && @agent.organization_id == recipient.organization_id
  end

  def assert_delivery_participants!
    ids = [ @delivery.caller_agent_id, @delivery.recipient_agent_id ].uniq
    unless @delivery.organization.agents.admitted.where(id: ids).count == ids.size
      raise Agent::Unadmitted
    end
    raise RelayDelivery::Expired if @delivery.reload.expired_at?
  end

  def assert_delivery_fence!(holder, fence)
    unless @delivery.holder == holder && @delivery.fence == fence && @delivery.phase.in?(%w[sending held])
      raise RelayDelivery::LostFence
    end
  end

  # Revalidate at provider entry and again after DNS/before HTTP. An expired
  # pre-connect sender must not borrow a successor's cross-process capacity.
  def assert_connection_admission!(slot, holder, fence)
    @delivery.with_lock do
      assert_delivery_participants!
      assert_delivery_fence!(holder, fence)
      unless @delivery.phase == "sending" && @delivery.deadline_at && @delivery.deadline_at > Time.current &&
          Agent.native_outbound_available? && slot.reload.held_by?(holder) && slot.renew(holder)
        raise RelayDelivery::LostFence
      end
    end
    true
  rescue RelayDelivery::LostFence
    recover_receipt(@delivery)
    raise
  ensure
    ActiveRecord::Base.connection_pool.release_connection
  end

  def ensure_native_mutation_available!(task, current_delivery: nil)
    task.lock!
    mapping = task.relay_task
    if mapping
      mapping.lock!
      mapping.invalidate_observation! if mapping.lease_holder.present?
      @mapping_fence = mapping.fence
    end
    pending = task.relay_deliveries.where(phase: %w[reserved sending])
    pending = pending.where.not(id: current_delivery.id) if current_delivery
    raise RelayDelivery::Busy if pending.exists?
  end

  def without_database_connection
    # Never lease a database connection across upstream/token HTTP. No dispatch
    # transaction encloses this boundary; synthetic transactional tests are local.
    ActiveRecord::Base.connection_pool.release_connection
    yield
  ensure
    ActiveRecord::Base.connection_pool.release_connection
  end

  def cancel_native(task, metadata:)
    metadata = metadata_of("metadata" => hash(metadata))
    mapping = task.relay_task
    raise A2a::Error.new(:task_not_cancelable) unless mapping && mapping.native_task_id.present?
    @delivery = nil
    task.recipient_agent.with_lock do
      assert_participants!(task.recipient_agent)
      ensure_native_mutation_available!(task)
      @mapping_fence = mapping.reload.fence
      @after_sequence = task.events.maximum(:id) || 0
      @delivery = RelayDelivery.reserve!(caller: @agent, recipient: task.recipient_agent, task: task,
        message: { "messageId" => SecureRandom.uuid, "taskId" => task.id }, operation: "CancelTask",
        execution_route: "native", route_snapshot: mapping.route_snapshot)
    end
    answer, = dispatch_native(metadata: metadata, modes: [])
    raise A2a::NativeResult::Invalid unless answer.is_a?(Task)
    A2a::Serializer.task(answer)
  rescue RelayDelivery::Busy
    raise delivery_error("RELAY_MUTATION_BUSY")
  rescue RelayDelivery::Expired, RelayDelivery::Pending, RelayDelivery::LostFence
    raise delivery_error("RELAY_DELIVERY_PENDING")
  rescue Agent::Unadmitted
    raise A2a::Error.new(:task_not_found)
  end

  def wait_for_native_settlement(task, deadline:)
    current = locate(task.id)
    raise delivery_error("RELAY_WAIT_LIMIT") if monotonic >= deadline
    return current if native_settled?(current)
    raise delivery_error("RELAY_WAIT_LIMIT") unless A2a::Waiters.acquire(@agent.organization_id)
    begin
      loop do
        current = locate(task.id)
        remaining = deadline - monotonic
        raise delivery_error("RELAY_WAIT_LIMIT") if remaining <= 0
        return current if native_settled?(current)
        A2a::Waiters.idle([ self.class.poll_interval, remaining ].min)
      end
    ensure
      A2a::Waiters.release(@agent.organization_id)
      ActiveRecord::Base.connection_pool.release_connection
    end
  end

  def native_settled?(task)
    return false if task.held? || !(task.terminal? || task.interrupted?)
    task.events.where(kind: %w[status snapshot_boundary], settlement_evidence: true).where("id > ?", @after_sequence || 0).exists?
  end
end
