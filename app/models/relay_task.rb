require "digest"
require "time"

# Maps one native execution. Snapshot imports never use inbox record/transition
# APIs, including when a native executor first returns a terminal Task (§4.1.1).
class RelayTask < ApplicationRecord
  include Following
  include NativeEvents
  class InvalidSnapshot < StandardError; end
  class LostLease < StandardError; end

  SNAPSHOT_FIELDS = %w[endpoint_url resource tenant generation native_streaming].freeze
  ROUTE_FIELDS = (%w[organization_id caller_agent_id recipient_agent_id native_task_id native_context_id task_id] + SNAPSHOT_FIELDS).freeze
  SNAPSHOT_LIMIT = 2.megabytes
  TASK_LIMIT = 16.megabytes

  belongs_to :task
  belongs_to :organization
  belongs_to :caller_agent, class_name: "Agent"
  belongs_to :recipient_agent, class_name: "Agent"

  validates :endpoint_url, :resource, :generation, :native_task_id, presence: true
  validate :same_task_parties
  validate :immutable_route, on: :update

  def route_snapshot
    attributes.slice(*SNAPSHOT_FIELDS)
  end

  def import_snapshot!(snapshot, observed_at: Time.current, fence: nil)
    raise InvalidSnapshot unless snapshot.is_a?(Hash) && snapshot.to_json.bytesize <= SNAPSHOT_LIMIT
    snapshot = snapshot.deep_stringify_keys
    A2a::NativeResult.validate_task!(snapshot)
    validate_snapshot!(snapshot)
    semantic = snapshot.deep_dup
    semantic.fetch("status").delete("timestamp")
    digest = Digest::SHA256.hexdigest(RelayDelivery.canonical_json(semantic))
    with_lock do
      task.lock!
      raise Agent::Unadmitted unless task.participants_admitted?
      raise LostLease if fence && (self.fence != fence || lease_expires_at.nil? || lease_expires_at <= Time.current)
      if snapshot_digest == digest
        update!(observed_at: observed_at, upstream_status_at: parse_timestamp(snapshot.dig("status", "timestamp")), stale: false)
        return task
      end
      raise InvalidSnapshot if task.terminal? && task.state != snapshot.dig("status", "state")
      message_context = context_for_messages(snapshot)
      if native_context_id.nil? && message_context && native_message_context.nil?
        RelayContext.map!(caller: caller_agent, recipient: recipient_agent, generation: generation,
          public_context_id: task.context_id, native_context_id: message_context)
      end

      status = snapshot.fetch("status")
      status_changed = status_changed?(status, observed_at: observed_at)
      history = Array(snapshot["history"])
      position_base = native_history_offset(history)
      status_message = nil
      base_changed = false
      history.each_with_index do |message, position|
        imported = import_message!(message, native_position: position_base + position)
        base_changed ||= imported.previous_changes.any?
        status_message = imported if message == status["message"]
      end
      if status["message"] && !status_message
        status_message = import_message!(status["message"])
        base_changed ||= status_message.previous_changes.any?
      end
      Array(snapshot["artifacts"]).each_with_index do |artifact, position|
        changed = import_artifact!(artifact, native_position: position)
        base_changed ||= changed
      end
      if snapshot.key?("artifacts")
        removed = task.artifacts.where.not(native_artifact_id: snapshot["artifacts"].map { |artifact| artifact["artifactId"] }).to_a
        removed.each(&:destroy!)
        base_changed ||= removed.any?
      end
      retained = task.messages.sum { |message| message.attributes.slice("parts", "metadata", "extensions").to_json.bytesize } +
        task.artifacts.sum { |artifact| artifact.attributes.slice("parts", "metadata", "extensions", "name", "description").to_json.bytesize }
      raise InvalidSnapshot if retained > TASK_LIMIT

      # A new snapshot base is not a made-up artifact delta (§4.2.2). Streams
      # stop at this immutable boundary and resubscribe to the new local base.
      task.events.create!(kind: "snapshot_boundary", settlement_evidence: false, payload: { "taskId" => task.id, "contextId" => task.context_id }, created_at: observed_at) if snapshot_digest.present? && base_changed
      attrs = { state: status.fetch("state"), status_message_id: status_message&.message_id, content_changed_at: observed_at }
      attrs[:status_at] = observed_at if status_changed
      task.update!(attrs)
      if status_changed
        task.events.create!(kind: "status", state: task.state, status_message_id: task.status_message_id, settlement_evidence: true,
          payload: translated_status(status, observed_at: observed_at), upstream_timestamp: status["timestamp"], created_at: observed_at)
      end
      update!(upstream_metadata: snapshot["metadata"] || {}, upstream_status_at: parse_timestamp(status["timestamp"]),
        observed_at: observed_at, changed_at: observed_at, snapshot_digest: digest, stale: false)
      check_retained_budget!
    end
    task.reload
  rescue A2a::NativeResult::Invalid
    raise InvalidSnapshot
  end

  # Only new native status semantics can settle an input. A different snapshot
  # base or timestamp is not a new interruption (A2A §3.2.2; relay plan §11).
  def status_changed?(status, observed_at: Time.current)
    previous = task.events.where(kind: %w[status snapshot_boundary], settlement_evidence: true).order(:id).last&.payload&.fetch("status", nil)
    previous&.except("timestamp") != translated_status(status, observed_at: observed_at).fetch("status").except("timestamp")
  end

  private

  # GetTask may return a bounded suffix (§3.2.4). Anchor it to a known message
  # so a fresh base can backfill older history without scrambling that prefix.
  def native_history_offset(history)
    positions = task.messages.where.not(native_position: nil).pluck(:role, :native_message_id, :native_position)
      .to_h { |role, id, position| [ [ role, id ], position ] }
    history.each_with_index do |message, index|
      position = positions[[ message["role"], message["messageId"] ]]
      return position - index unless position.nil?
    end
    task.messages.maximum(:native_position).to_i + 1
  end


  def same_task_parties
    return unless task
    unless [ "native", "held" ].include?(task.execution_route) && task.organization_id == organization_id &&
        task.caller_agent_id == caller_agent_id && task.recipient_agent_id == recipient_agent_id
      errors.add(:base, "native mapping must match its task parties")
    end
  end

  def immutable_route
    errors.add(:base, "immutable native execution") if ROUTE_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
  end

  def validate_snapshot!(snapshot)
    raise InvalidSnapshot unless snapshot["id"] == native_task_id && snapshot["contextId"] == native_context_id
    status = snapshot["status"]
    raise InvalidSnapshot unless status.is_a?(Hash) && Task::STATES.include?(status["state"])
    raise InvalidSnapshot unless snapshot["metadata"].nil? || snapshot["metadata"].is_a?(Hash)
    parse_timestamp(status["timestamp"])
    %w[history artifacts].each do |field|
      raise InvalidSnapshot unless snapshot[field].nil? || snapshot[field].is_a?(Array)
    end
    expected_context = context_for_messages(snapshot)
    Array(snapshot["history"]).each { |message| validate_message!(message, expected_context: expected_context) }
    validate_message!(status["message"], expected_context: expected_context) if status["message"]
    Array(snapshot["artifacts"]).each do |artifact|
      raise InvalidSnapshot unless artifact.is_a?(Hash) && artifact["artifactId"].is_a?(String) && artifact["artifactId"].present? && artifact["parts"].is_a?(Array) && artifact["parts"].any?
    end
  end

  def validate_message!(message, expected_context:)
    raise InvalidSnapshot unless message.is_a?(Hash) && message["messageId"].is_a?(String) && message["messageId"].present? && Message::ROLES.include?(message["role"])
    if message.key?("contextId")
      raise InvalidSnapshot unless message["contextId"] == expected_context
    elsif message["role"] != "ROLE_USER"
      raise InvalidSnapshot
    end
    raise InvalidSnapshot if message["taskId"] && message["taskId"] != native_task_id
    raise InvalidSnapshot unless message["parts"].is_a?(Array) && message["parts"].any?
    if message["role"] == "ROLE_USER"
      raise InvalidSnapshot unless request_echo(message)
    end
    Array(message["referenceTaskIds"]).each { |id| public_reference(id) }
  end

  def import_message!(message, native_position: nil)
    attrs = { sender_agent_id: message["role"] == "ROLE_AGENT" ? recipient_agent_id : caller_agent_id,
      parts: message.fetch("parts"), metadata: message_metadata(message), extensions: message["extensions"] || [],
      reference_task_ids: Array(message["referenceTaskIds"]).map { |id| public_reference(id) },
      native_task_id: message["taskId"], native_context_id: message["contextId"] }
    row = task.messages.find_by(role: message.fetch("role"), native_message_id: message.fetch("messageId"))
    if row.nil? && message["role"] == "ROLE_USER"
      row = task.messages.find_by(role: "ROLE_USER", sender_agent_id: caller_agent_id, client_message_id: message.fetch("messageId"))
    end
    row ||= task.messages.build(role: message.fetch("role"))
    row.native_message_id = message.fetch("messageId")
    row.created_at ||= request_echo(message)&.created_at if message["role"] == "ROLE_USER"
    row.native_position = native_position || row.native_position || task.messages.maximum(:native_position).to_i + 1
    row.assign_attributes(attrs)
    row.save! if row.new_record? || row.changed?
    row
  end

  def import_artifact!(artifact, native_position: nil)
    row = task.artifacts.find_or_initialize_by(native_artifact_id: artifact.fetch("artifactId"))
    row.native_position = native_position || row.native_position || task.artifacts.maximum(:native_position).to_i + 1
    row.assign_attributes(name: artifact["name"], description: artifact["description"], parts: artifact.fetch("parts"),
      metadata: artifact["metadata"] || {}, extensions: artifact["extensions"] || [])
    row.save! if row.new_record? || row.changed?
    row.previous_changes.any?
  end

  def translated_status(status, observed_at:)
    payload = { "taskId" => task.id, "contextId" => task.context_id, "status" => status.deep_dup }
    payload["status"]["timestamp"] = A2a::Serializer.timestamp(observed_at)
    if payload.dig("status", "message")
      message = payload["status"]["message"]
      message["taskId"] = task.id if message["taskId"]
      message["contextId"] = task.context_id if message.key?("contextId")
      metadata = message_metadata(message)
      message["metadata"] = metadata if metadata.any? || message.key?("metadata")
      message["referenceTaskIds"] = Array(message["referenceTaskIds"]).map { |id| public_reference(id) } if message.key?("referenceTaskIds")
    end
    payload
  end

  def public_reference(id)
    mapped = organization.relay_tasks.where(recipient_agent_id: recipient_agent_id,
      caller_agent_id: caller_agent_id, generation: generation, native_task_id: id).first
    raise InvalidSnapshot unless mapped && Task.visible_to(caller_agent).exists?(mapped.task_id)
    mapped.task_id
  end

  def request_echo(message)
    scope = organization.relay_deliveries.where(caller_agent_id: caller_agent_id, recipient_agent_id: recipient_agent_id)
    references = Array(message["referenceTaskIds"]).map { |id| public_reference(id) }
    retained = task.messages.where(role: "ROLE_USER", sender_agent_id: caller_agent_id)
      .find_by(native_message_id: message["messageId"]) ||
      task.messages.where(role: "ROLE_USER", sender_agent_id: caller_agent_id).find_by(client_message_id: message["messageId"])
    if retained && retained.parts == message["parts"] && clean_metadata(retained.metadata) == clean_metadata(message["metadata"]) &&
        retained.extensions == (message["extensions"] || []) && retained.reference_task_ids == references
      return retained
    end
    scope.where(task_id: task.id).or(scope.where(reserved_task_id: task.id)).detect do |delivery|
      request = delivery.request_payload
      next false unless request && request["messageId"] == message["messageId"]
      request["parts"] == message["parts"] && clean_metadata(request["metadata"]) == clean_metadata(message["metadata"]) &&
        (request["extensions"] || []) == (message["extensions"] || []) &&
        (request["referenceTaskIds"] || []) == Array(message["referenceTaskIds"]).map { |id| public_reference(id) }
    end
  end

  def native_message_context
    native_context_id || organization.relay_contexts.where(caller_agent_id: caller_agent_id,
      recipient_agent_id: recipient_agent_id, generation: generation, public_context_id: task.context_id).pick(:native_context_id)
  end

  def context_for_messages(snapshot)
    return native_message_context if native_message_context
    messages = Array(snapshot["history"]) + [ snapshot.dig("status", "message") ].compact
    contexts = messages.filter_map { |message| message["contextId"] }.uniq
    raise InvalidSnapshot if contexts.size > 1
    contexts.first
  end

  def clean_metadata(metadata)
    (metadata || {}).reject { |key, _| key.start_with?("concourse.") }
  end

  def message_metadata(message)
    metadata = clean_metadata(message["metadata"])
    return metadata unless message["role"] == "ROLE_USER"
    evidence = request_echo(message)
    raise InvalidSnapshot unless evidence
    trusted = evidence.is_a?(Message) ? evidence.metadata : evidence.request_payload["metadata"]
    metadata.merge((trusted || {}).select { |key, _| key.start_with?("concourse.") })
  end

  def parse_timestamp(value)
    return if value.nil?
    raise InvalidSnapshot unless value.is_a?(String)
    Time.iso8601(value)
  rescue ArgumentError
    raise InvalidSnapshot
  end
end
