class Message < ApplicationRecord
  # A2A v1.0 Role. JSON values are the proto names (ROLE_USER, ROLE_AGENT).
  ROLES = %w[ROLE_USER ROLE_AGENT].freeze

  self.primary_key = "message_id"
  self.implicit_order_column = "created_at"

  belongs_to :task, touch: true
  belongs_to :sender_agent, class_name: "Agent"

  validates :role, inclusion: { in: ROLES }
  validates :parts, presence: true
  validates :client_message_id, uniqueness: { scope: :sender_agent_id }, allow_nil: true
  validate :parts_are_a_list

  before_validation :assign_message_id, on: :create
  after_create :record_caller_input, if: -> { Concourse.v3? && task.inbox? && role == "ROLE_USER" && sender_agent_id == task.caller_agent_id }
  after_create -> { AgentEvent.message_created!(self) }
  after_save -> { task.mark_content_changed! }
  after_create_commit :ring_doorbell

  # Agent messages are the recipient's. User messages are the caller's.
  # Neither may be added once the task is terminal (spec §3.1.2).
  def self.record!(task:, role:, sender:, parts:, metadata: {}, message_id: nil, extensions: [], reference_task_ids: [])
    task.ensure_inbox!
    raise Task::Terminal if task.terminal?

    case role
    when "ROLE_AGENT"
      raise Task::NotRecipient unless sender&.id == task.recipient_agent_id
    when "ROLE_USER"
      raise Task::NotCaller unless sender&.id == task.caller_agent_id
    else
      raise ArgumentError, "unknown role"
    end

    create!(
      client_message_id: message_id.presence,
      task: task,
      role: role,
      sender_agent: sender,
      parts: parts,
      metadata: metadata || {},
      extensions: extensions || [],
      reference_task_ids: reference_task_ids || []
    )
  end

  # The id the client sent. The primary key is internal so two callers can
  # reuse a messageId without confirming that the other one exists.
  def wire_message_id
    native_message_id.presence || client_message_id.presence || message_id
  end

  # Resolve only this Message's unique recorded input event, never the Task's
  # latest pointer. Missing or ambiguous legacy evidence supplies no receipt.
  def recorded_caller_input
    return unless Concourse.v3? && task.inbox? && role == "ROLE_USER" && sender_agent_id == task.caller_agent_id
    matches = task.events.where(kind: "caller_input").where("json_extract(payload, '$.message_id') = ?", message_id).limit(2).to_a
    return unless matches.one? && matches.first.payload == { "message_id" => message_id }
    cursor = matches.first.id.to_s
    return unless cursor.match?(/\A[1-9][0-9]*\z/) && wire_message_id.is_a?(String) && wire_message_id.present?

    { "cursor" => cursor, "messageId" => wire_message_id }
  end

  private

  def record_caller_input
    # A2A §3.2.2: accepted caller input supersedes a prior input request.
    # Event IDs order this fact even with equal timestamps; it is not a wire status.
    task.events.create!(kind: "caller_input", payload: { "message_id" => message_id }, created_at: created_at)
  end

  def ring_doorbell
    committed_task = task.organization.tasks.find_by(id: task_id)
    return unless committed_task&.inbox?
    if role == "ROLE_AGENT" && sender_agent_id == committed_task.recipient_agent_id
      committed_task.ring_doorbell("reply")
    elsif role == "ROLE_USER" && sender_agent_id == committed_task.caller_agent_id && committed_task.actionable?
      committed_task.ring_doorbell("inbox")
    end
  end

  def assign_message_id
    self.message_id ||= SecureRandom.uuid
  end

  def parts_are_a_list
    errors.add(:parts, "must be a list") unless parts.is_a?(Array)
  end
end
