require "digest"

# A receipt is a dispatch fence, not an executor or an A2A task. Send idempotency
# is optional upstream (A2A §3.3.1); a pending/held receipt is never reclaimed.
class RelayDelivery < ApplicationRecord
  class Mismatch < StandardError; end
  class Pending < StandardError; end
  class Expired < StandardError; end
  class LostFence < StandardError; end
  class Busy < StandardError; end

  PHASES = %w[reserved sending held accepted rejected].freeze
  PENDING_PHASES = %w[reserved sending held].freeze
  ROUTE_FIELDS = %w[organization_id caller_agent_id recipient_agent_id endpoint_url resource tenant generation native_streaming].freeze
  IMMUTABLE_FIELDS = (ROUTE_FIELDS + %w[reserved_task_id operation message_id_digest request_digest execution_route after_sequence]).freeze
  UNSENT_EVIDENCE = %w[dns_unavailable tcp_refused tcp_unreachable connect_timeout tls_network_failure].freeze
  PAYLOAD_LIMIT = 2.megabytes

  belongs_to :organization
  belongs_to :caller_agent, class_name: "Agent"
  belongs_to :recipient_agent, class_name: "Agent"
  belongs_to :task, optional: true

  scope :pending, -> { where(phase: PENDING_PHASES, expired_at: nil) }
  scope :visible_to, ->(agent) {
    where(organization_id: agent.organization_id).where(caller_agent_id: agent.id).or(
      where(organization_id: agent.organization_id, recipient_agent_id: agent.id)
    )
  }

  validates :reserved_task_id, :operation, :message_id_digest, :request_digest, :content_changed_at, presence: true
  validates :phase, inclusion: { in: PHASES }
  validates :execution_route, inclusion: { in: %w[inbox native] }
  validate :immutable_fields, on: :update
  validate :same_parties
  validate :bounded_payloads
  before_validation -> { self.id ||= SecureRandom.uuid }, on: :create
  # Destroying a receipt would reopen its message ID. Retention scrubs instead.
  before_destroy -> { throw :abort }

  # Pre-receipt sends have only a Message dedupe key. Preserve that fence, not
  # their content, when purging. insert_all leaves existing receipts untouched
  # and bypasses current-party validation: a historical party may have moved.
  # These already-expired rows can never reserve or replay executable work.
  def self.expire_legacy_message!(message)
    task = message.task
    insert_all([ {
      id: SecureRandom.uuid, organization_id: task.organization_id,
      caller_agent_id: message.sender_agent_id, recipient_agent_id: task.recipient_agent_id,
      reserved_task_id: task.id, public_task_id: task.id, operation: "SendMessage",
      message_id_digest: Digest::SHA256.hexdigest(message.client_message_id),
      request_digest: Digest::SHA256.hexdigest(""), execution_route: "inbox",
      phase: "accepted", outcome: "accepted", fence: 1, expired_at: Time.current,
      content_changed_at: task.updated_at
    } ], unique_by: :index_relay_deliveries_on_caller_and_message_digest)
  end

  def self.reserve!(caller:, recipient:, message:, operation: "SendMessage", task: nil, execution_route: "inbox", route_snapshot: nil, request_digest: nil)
    message = message.deep_stringify_keys
    message_id = message.fetch("messageId")
    raise Mismatch unless message_id.is_a?(String) && message_id.present?

    digest = Digest::SHA256.hexdigest(message_id)
    request_digest ||= Digest::SHA256.hexdigest(canonical_json(message))
    recipient.with_lock do
      existing = where(caller_agent_id: caller.id, message_id_digest: digest).first # tenancy-ok: caller's own dedupe fence survives moves
      if existing
        raise Mismatch unless existing.replays?(caller:, recipient:, operation:, request_digest:)
        raise Agent::Unadmitted unless existing.participants_admitted?
        raise Mismatch if task && existing.public_task_id != task.id
        raise Expired if existing.expired_at?
        return existing
      end
      raise Agent::Unadmitted unless caller.admitted? && recipient.admitted? && caller.organization_id == recipient.organization_id

      if task
        raise Mismatch unless Task.visible_to(caller).exists?(task.id) && task.caller_agent_id == caller.id && task.recipient_agent_id == recipient.id
        raise Busy if task.relay_deliveries.where(phase: %w[reserved sending]).exists?
        raise Busy if operation == "SendMessage" && task.input_delivery_unconfirmed?
        raise Mismatch unless execution_route == (task.inbox? ? "inbox" : "native")
      end
      snapshot = (route_snapshot || {}).symbolize_keys.slice(:endpoint_url, :resource, :tenant, :generation, :native_streaming)
      if execution_route == "native"
        raise Mismatch if snapshot[:endpoint_url].blank? || snapshot[:resource].blank? || snapshot[:generation].nil?
      elsif snapshot.any?
        raise Mismatch
      end
      delivery = create!(**snapshot, organization: recipient.organization, caller_agent: caller, recipient_agent: recipient,
        task: task, reserved_task_id: task&.id || SecureRandom.uuid, public_task_id: task&.id,
        operation: operation, message_id_digest: digest, request_digest: request_digest, request_payload: message,
        execution_route: execution_route, content_changed_at: Time.current, after_sequence: task&.events&.maximum(:id) || 0)
      task.mark_content_changed! if task
      delivery
    end
  rescue ActiveRecord::RecordNotUnique
    existing = where(caller_agent_id: caller.id, message_id_digest: digest).first
    raise Busy unless existing
    raise Mismatch unless existing.replays?(caller:, recipient:, operation:, request_digest:)
    raise Agent::Unadmitted unless existing.participants_admitted?
    raise Mismatch if task && existing.public_task_id != task.id
    raise Expired if existing.expired_at?
    existing
  end

  # The same caller reusing a messageId with the same recipient gets the
  # original result back. On the inbox route the body is not compared: that
  # is the contract Concourse shipped before receipts (and the A2A TCK reuses
  # one messageId across different requests); A2A leaves idempotency to the
  # server (§3.3.1). A native upstream may not dedupe, so a native receipt
  # refuses a different body under a reused id instead of hiding it.
  def replays?(caller:, recipient:, operation:, request_digest:)
    organization_id == caller.organization_id && recipient_agent_id == recipient.id && self.operation == operation &&
      (execution_route == "inbox" || self.request_digest == request_digest)
  end

  def self.canonical_json(value)
    case value
    when Hash then "{#{value.keys.sort.map { |key| "#{key.to_json}:#{canonical_json(value[key])}" }.join(',')}}"
    when Array then "[#{value.map { |item| canonical_json(item) }.join(',')}]"
    else value.to_json
    end
  end

  def route_snapshot
    attributes.slice(*ROUTE_FIELDS)
  end

  def participants_admitted?
    ids = [ caller_agent_id, recipient_agent_id ].uniq
    organization.agents.admitted.where(id: ids).count == ids.size
  end

  def start_sending!(holder:, deadline_at:)
    with_lock do
      raise Expired if expired_at?
      raise Pending unless phase == "reserved" && execution_route == "native"
      raise Agent::Unadmitted unless participants_admitted?
      raise ArgumentError, "bounded holder deadline required" unless holder.present? && deadline_at > Time.current && deadline_at <= 15.seconds.from_now
      update!(phase: "sending", holder: holder, fence: fence + 1, deadline_at: deadline_at)
    end
    self
  end

  def hold!(holder:, fence:, task: nil)
    with_lock do
      check_fence!(holder, fence)
      raise LostFence unless phase == "sending"
      attach_task!(task) if task
      update!(phase: "held", outcome: "unconfirmed")
    end
    self
  end

  def accept!(result:, holder: nil, fence: nil, task: nil)
    settle!(phase: "accepted", outcome: "accepted", result: result, holder: holder, fence: fence, task: task)
  end

  def reject!(result:, holder: nil, fence: nil)
    settle!(phase: "rejected", outcome: "rejected", result: result, holder: holder, fence: fence)
  end

  def reject_reserved!(result:)
    with_lock do
      raise Expired if expired_at?
      raise LostFence unless phase == "reserved"
      if participants_admitted?
        update!(phase: "rejected", outcome: "configuration_rejected", result_payload: result, content_changed_at: Time.current)
      else
        expire!
      end
    end
    self
  end

  def recover_expired_reservation!
    with_lock do
      if !expired_at? && phase == "reserved" && created_at <= 15.seconds.ago
        update!(phase: "rejected", outcome: "abandoned", result_payload: nil, fence: fence + 1)
      end
    end
    self
  end

  # Only the transport's positive pre-HTTP evidence may use this transition.
  # No exception class, status code or elapsed deadline is evidence (§3.3.1).
  def fallback_to_inbox!(holder:, fence:, evidence:, task: nil)
    with_lock do
      check_fence!(holder, fence)
      raise LostFence unless phase == "sending" && execution_route == "native"
      raise ArgumentError, "certain pre-HTTP evidence required" unless UNSENT_EVIDENCE.include?(evidence.to_s)
      raise Agent::Unadmitted unless participants_admitted?
      raise Mismatch if task_id.present? || (task && !task.inbox?)
      # The route change is deliberately unavailable through normal saves.
      update_columns(execution_route: "inbox", phase: "reserved", outcome: "unsent", holder: nil, deadline_at: nil, fence: self.fence + 1)
      attach_task!(task) if task
      save!
    end
    self
  end

  def replay!(allow_held: false)
    # Reload under the receipt lock: a retained Ruby payload is not permission
    # to disclose after another process scrubs content or removes a party.
    with_lock do
      raise Expired if expired_at?
      raise Agent::Unadmitted unless participants_admitted?
      # Tracking uncertainty is permitted, never acceptance or redispatch.
      held_tracking = allow_held && phase == "held" && operation == "SendMessage" && task_id.present?
      raise Pending unless phase.in?(%w[accepted rejected]) || held_tracking
      result_payload
    end
  end

  # Operation-only acceptance metadata (A2A §3.2.5), not a Task's latest input.
  # Retained legacy receipts remain readable, but never acquire new evidence.
  def send_receipt(for_task)
    return unless Concourse.v3? && execution_route == "inbox" && operation == "SendMessage" &&
      phase == "accepted" && !expired_at? && for_task.inbox? && task_id == for_task.id && public_task_id == for_task.id &&
      organization_id == for_task.organization_id && caller_agent_id == for_task.caller_agent_id && recipient_agent_id == for_task.recipient_agent_id
    result = result_payload
    return unless result.is_a?(Hash) && result["task"].is_a?(Hash) && result["task"]["id"] == for_task.id && !result.key?("message") && !result.key?("error")
    receipt = result["sendReceipt"]
    return unless receipt.is_a?(Hash) && receipt.keys.sort == %w[callerInput version] && receipt["version"].is_a?(Integer) && receipt["version"] == 1
    input = receipt["callerInput"]
    return unless input.is_a?(Hash) && input.keys.sort == %w[cursor messageId] &&
      input["cursor"].is_a?(String) && input["cursor"].match?(/\A[1-9][0-9]*\z/) &&
      input["messageId"].is_a?(String) && input["messageId"].present?
    internal_id = result["callerInputMessageId"]
    return unless internal_id.is_a?(String) && internal_id.present? && request_payload.is_a?(Hash) &&
      request_payload["messageId"] == input["messageId"] && Digest::SHA256.hexdigest(input["messageId"]) == message_id_digest
    message = for_task.messages.find_by(message_id: internal_id, role: "ROLE_USER", sender_agent_id: caller_agent_id)
    return unless message && message.recorded_caller_input == input

    receipt.deep_dup
  end

  # Neither recovery nor expiry sends anything, and neither infers cancellation.
  def recover_expired_holder!
    with_lock do
      return self if expired_at? || deadline_at.nil? || deadline_at > Time.current
      update!(phase: "held", outcome: "unconfirmed") if phase == "sending"
    end
    self
  end

  def expire!
    with_lock do
      return self if expired_at?
      # Expiry fences dispatch, including the active-mutation unique index.
      # A possible send stays uncertain; a reservation never reached HTTP (§3.3.1).
      resolution = case phase
      when "sending" then { phase: "held", outcome: "unconfirmed" }
      when "reserved" then { phase: "rejected", outcome: "abandoned" }
      else {}
      end
      update_columns({ request_payload: nil, result_payload: nil, endpoint_url: nil, resource: nil, tenant: nil,
        holder: nil, deadline_at: nil, expired_at: Time.current, fence: fence + 1 }.merge(resolution))
    end
    self
  end

  private

  def check_fence!(holder, fence)
    raise Expired if expired_at?
    raise LostFence unless holder.present? && self.holder == holder && self.fence == fence
  end

  def settle!(phase:, outcome:, result:, holder:, fence:, task: nil)
    with_lock do
      raise Expired if expired_at?
      if execution_route == "native"
        check_fence!(holder, fence)
        raise LostFence unless self.phase.in?(%w[sending held])
      else
        raise LostFence unless self.phase == "reserved"
      end
      unless participants_admitted?
        expire!
        return self
      end
      attach_task!(task) if task
      update!(phase: phase, outcome: outcome, result_payload: result, content_changed_at: Time.current)
    end
    self
  end

  def attach_task!(task)
    raise Mismatch unless task.organization_id == organization_id && task.caller_agent_id == caller_agent_id && task.recipient_agent_id == recipient_agent_id
    raise Mismatch if public_task_id.present? && public_task_id != task.id
    raise Mismatch if (execution_route == "inbox") != task.inbox?
    self.task = task
    self.public_task_id = task.id
  end

  def immutable_fields
    if phase_in_database.in?(%w[accepted rejected]) && will_save_change_to_result_payload?
      errors.add(:result_payload, "cannot change a settled receipt")
    end
    errors.add(:base, "immutable delivery route") if IMMUTABLE_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
    errors.add(:public_task_id, "cannot be remapped") if public_task_id_in_database.present? && will_save_change_to_public_task_id?
    errors.add(:task_id, "cannot be remapped") if task_id_in_database.present? && will_save_change_to_task_id?
    errors.add(:base, "expired receipt") if expired_at_in_database.present?
    if will_save_change_to_phase?
      allowed = { "reserved" => %w[sending accepted rejected], "sending" => %w[held accepted rejected], "held" => %w[accepted rejected] }
      errors.add(:phase, "cannot reopen dispatch") unless Array(allowed[phase_in_database]).include?(phase)
    end
  end

  def same_parties
    errors.add(:base, :across_organizations) if new_record? && [ caller_agent, recipient_agent ].compact.any? { |agent| agent.organization_id != organization_id }
    if task && (task.organization_id != organization_id || task.caller_agent_id != caller_agent_id || task.recipient_agent_id != recipient_agent_id)
      errors.add(:task, "must match delivery parties")
    end
  end

  def bounded_payloads
    [ request_payload, result_payload ].each do |payload|
      errors.add(:base, "relay payload too large") if payload && payload.to_json.bytesize > PAYLOAD_LIMIT
    end
    errors.add(:request_payload, "request too large") if request_payload && request_payload.to_json.bytesize > 1.megabyte
  end
end
