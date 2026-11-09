class TaskDelivery < ApplicationRecord
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  UNFINISHED = %w[queued prompting running uncertain].freeze

  belongs_to :organization
  belongs_to :task
  belongs_to :connection, class_name: "Agent::Connection"
  has_many :task_delivery_messages, dependent: :delete_all

  scope :unfinished, -> { where(phase: UNFINISHED) }

  # Called while holding the Task lock. Admission and CancelTask (§3.1.5)
  # share that lock, so only definitely unstarted work can be canceled.
  def self.publish!(task:, agent:, envelope:, outcome:)
    invalid! unless envelope.is_a?(Hash)
    envelope = envelope.stringify_keys
    invalid! unless envelope.keys.all? { |key| %w[operation id connectionId sessionId messageIds].include?(key) }
    invalid! unless %w[id connectionId].all? { |key| envelope[key].is_a?(String) && UUID.match?(envelope[key]) }
    invalid! unless envelope["sessionId"].is_a?(String) && Agent::Connection::SESSION_FORMAT.match?(envelope["sessionId"])
    invalid! unless task.recipient_agent_id == agent.id && task.inbox? && task.participants_admitted?
    connection = agent.connections.where(organization_id: task.organization_id).find_by(id: envelope["connectionId"], session_id: envelope["sessionId"])
    invalid! unless connection&.active?
    operation = envelope["operation"]
    existing = task.task_deliveries.find_by(id: envelope["id"])
    invalid! if operation != "settle" && outcome.values.any?(&:present?)
    if operation == "accept"
      return accept!(task, connection, envelope, existing)
    end
    invalid! unless existing && existing.session_id == connection.session_id
    invalid! if envelope.key?("messageIds") && envelope["messageIds"] != existing.message_ids
    if operation == "resume"
      # Rebind transport only. A2A send idempotency (§3.3.1) is not evidence
      # that possibly-started effects can safely be executed again.
      invalid! unless existing.phase.in?(UNFINISHED + [ "settled" ])
      invalid! if task.terminal? && existing.phase != "settled"
      existing.update!(connection: connection) unless existing.connection_id == connection.id
      return existing
    end
    invalid! unless existing.connection_id == connection.id
    if operation == "settle" && existing.phase == "settled"
      invalid! unless existing.settlement_digest == digest(outcome)
      return existing
    end
    invalid! if task.terminal?
    case operation
    when "prompt"
      invalid! unless existing.phase.in?(%w[queued prompting])
      existing.update!(phase: "prompting") unless existing.phase == "prompting"
    when "start"
      invalid! unless existing.phase.in?(%w[prompting running])
      unless existing.phase == "running"
        task.transition_to!("TASK_STATE_WORKING", by: agent) unless task.state == "TASK_STATE_WORKING"
        existing.update!(phase: "running")
      end
    when "uncertain"
      invalid! unless existing.phase.in?(%w[prompting running uncertain])
      existing.update!(phase: "uncertain") unless existing.phase == "uncertain"
    when "settle"
      invalid! unless existing.phase == "running" && outcome.values.any?(&:present?)
      # Explicit progress may finish this batch while the A2A Task remains
      # WORKING. Neither batch settlement nor SDK settlement is job completion.
      invalid! if outcome[:state].in?(%w[TASK_STATE_CANCELED TASK_STATE_SUBMITTED])
      if outcome[:state] == "TASK_STATE_COMPLETED"
        claimed = task.task_deliveries.joins(:task_delivery_messages).select("task_delivery_messages.message_id")
        pending = task.messages.where(role: "ROLE_USER", sender_agent_id: task.caller_agent_id).where.not(message_id: claimed)
        invalid! if pending.exists?
      end
      yield
      existing.update!(phase: "settled", settlement_digest: digest(outcome))
    else
      invalid!
    end
    existing
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    invalid!
  end

  def self.accept!(task, connection, envelope, existing)
    ids = envelope["messageIds"]
    invalid! unless ids.is_a?(Array) && ids.size.between?(1, 100) && ids.all? { |id| id.is_a?(String) && id.present? } && ids.uniq == ids
    if existing
      invalid! unless existing.message_ids == ids && existing.session_id == connection.session_id && existing.phase != "canceled"
      return existing if existing.connection_id == connection.id
      invalid! unless existing.phase == "queued" && !task.terminal?
      existing.update!(connection: connection)
      return existing
    end
    invalid! if task.terminal? || task.task_deliveries.unfinished.exists?
    messages = task.messages.where(role: "ROLE_USER", sender_agent_id: task.caller_agent_id)
      .where("COALESCE(NULLIF(native_message_id, ''), NULLIF(client_message_id, ''), message_id) IN (?)", ids).limit(101).to_a
    invalid! unless messages.size == ids.size
    invalid! if TaskDeliveryMessage.where(message_id: messages.map(&:message_id)).exists? # tenancy-ok: IDs from this task's genuine caller messages only
    claim = task.task_deliveries.create!(id: envelope["id"], organization: task.organization, connection: connection,
      session_id: connection.session_id, message_ids: ids)
    messages.each { |message| claim.task_delivery_messages.create!(message_id: message.message_id) }
    claim
  end
  private_class_method :accept!

  def to_h
    { "id" => id, "phase" => phase, "messageIds" => message_ids, "sessionId" => session_id }
  end

  # This is delivery information, not TaskState (§4.1.3). Never synthesize
  # COMPLETED or CANCELED from lease expiry or a transport receipt.
  def self.receipt(task, message_id: nil)
    scope = task.task_deliveries
    scope = scope.joins(:task_delivery_messages).where(task_delivery_messages: { message_id: message_id }) if message_id
    claim = scope.order(created_at: :desc).first
    state = case claim&.phase
    when "queued" then "queued"
    when "prompting" then claim.connection.active? ? "delivered" : "uncertain"
    when "running" then claim.connection.active? ? "running" : "uncertain"
    when "uncertain" then "uncertain"
    when "settled" then "delivered"
    when "canceled" then "accepted"
    else "accepted"
    end
    { "state" => state, "taskId" => task.id, "taskStatus" => task.state, "accepted" => true,
      "observedAt" => (claim&.updated_at || task.created_at).utc.iso8601(6) }
  end

  def self.digest(outcome)
    Digest::SHA256.hexdigest(RelayDelivery.canonical_json(outcome.stringify_keys))
  end
  private_class_method :digest

  def self.invalid!
    raise A2a::Error.new(:invalid_params)
  end
  private_class_method :invalid!
end
