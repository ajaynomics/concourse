class Task < ApplicationRecord
  include OwnerActions
  include InboxDoorbell

  class NotRecipient < StandardError; end
  class NotCaller < StandardError; end
  class InvalidTransition < StandardError; end
  class Terminal < StandardError; end
  class NotInbox < NotRecipient; end

  EXECUTION_ROUTES = %w[inbox native held].freeze

  # A2A v1.0 §4.1.3 TaskState. The JSON values are the proto names.
  STATES = %w[
    TASK_STATE_SUBMITTED
    TASK_STATE_WORKING
    TASK_STATE_COMPLETED
    TASK_STATE_FAILED
    TASK_STATE_CANCELED
    TASK_STATE_INPUT_REQUIRED
    TASK_STATE_REJECTED
    TASK_STATE_AUTH_REQUIRED
  ].freeze

  # Terminal states are final: a task cannot restart (life of a task;
  # spec §3.1.2 and §3.2.2 name the same four).
  TERMINAL_STATES = %w[
    TASK_STATE_COMPLETED
    TASK_STATE_FAILED
    TASK_STATE_CANCELED
    TASK_STATE_REJECTED
  ].freeze

  # Interrupted, not terminal. A blocking SendMessage returns at these too
  # (spec §3.2.2). The recipient may still move the task on.
  INTERRUPTED_STATES = %w[
    TASK_STATE_INPUT_REQUIRED
    TASK_STATE_AUTH_REQUIRED
  ].freeze

  self.implicit_order_column = "created_at"

  belongs_to :organization
  belongs_to :recipient_agent, class_name: "Agent", inverse_of: :received_tasks
  belongs_to :caller_agent, class_name: "Agent", inverse_of: :sent_tasks
  belongs_to :status_message, class_name: "Message", foreign_key: :status_message_id, primary_key: :message_id, optional: true
  has_many :messages, dependent: :destroy
  has_many :artifacts, dependent: :destroy
  has_many :events, class_name: "TaskEvent", dependent: :delete_all
  has_many :agent_events, dependent: :delete_all
  has_one :relay_task, dependent: :destroy
  has_many :relay_deliveries, dependent: :nullify
  has_many :task_deliveries, dependent: :destroy

  validates :context_id, presence: true
  validates :state, inclusion: { in: STATES }
  validate :agents_share_the_organization, on: :create
  validates :execution_route, inclusion: { in: EXECUTION_ROUTES }
  validate :immutable_execution_route, on: :update

  before_validation :assign_ids, on: :create
  before_save :track_inbox_content
  before_destroy :expire_delivery_fences, prepend: true, unless: -> { @retiring_message_tracking }
  after_save :record_status_event, if: :status_changed_for_event?
  after_commit :schedule_owner_alert, on: %i[create update], if: :waiting_on_a_person?

  # One stream per organization for every page that lists tasks. Per-task
  # streams would miss a list that is not subscribed to each row.
  broadcasts_refreshes_to ->(task) { [ task.organization, "tasks" ] }

  # The only way to reach tasks. A2A §13.1: a client sees the tasks it sent
  # or received, and nothing else. A task stays in the organization it was
  # sent in, so moves or removal of either participant end agent access.
  scope :visible_to, ->(agent) {
    admitted = agent.organization.agents.admitted.select(:id)
    where(organization_id: agent.organization_id).and(where(recipient_agent: agent).or(where(caller_agent: agent)))
      .where(caller_agent_id: admitted, recipient_agent_id: admitted).skip_query_cache!
  }

  def self.open!(recipient:, caller:, context_id: nil)
    create!(
      organization: recipient.organization,
      recipient_agent: recipient,
      caller_agent: caller,
      context_id: context_id.presence || SecureRandom.uuid,
      state: "TASK_STATE_SUBMITTED",
      status_at: Time.current
    )
  end

  # Owner HTML pages use this, not visible_to. visible_to is the agent
  # credential's scope (§13.1). A signed-in person sees every task any of
  # their agents sent or received: the owner-side scope, not a way for an
  # agent request to reach another agent's tasks.
  def self.involving_owner(owner)
    ids = owner.agents.select(:id)
    where(caller_agent_id: ids).or(where(recipient_agent_id: ids))
  end

  scope :unfinished, -> { where.not(state: TERMINAL_STATES) }
  scope :finished, -> { where(state: TERMINAL_STATES) }
  scope :inbox, -> { where(execution_route: "inbox") }

  EXECUTION_ROUTES.each do |route|
    define_method("#{route}?") { execution_route == route }
  end

  # This classifies an initial uncertainty after verified acceptance; it never
  # changes executor or enables inbox execution. The original native receipt
  # and imported mapping must prove the same route under the same send fence.
  def confirm_native_observation!(delivery:, holder:, fence:)
    delivery.with_lock do
      with_lock do
        mapping = relay_task
        same_route = mapping && mapping.snapshot_digest.present? &&
          mapping.route_snapshot == delivery.route_snapshot.slice(*RelayTask::SNAPSHOT_FIELDS)
        unless held? && same_route && delivery.execution_route == "native" &&
            delivery.phase.in?(%w[sending held]) && !delivery.expired_at? &&
            delivery.holder == holder && delivery.fence == fence &&
            delivery.reserved_task_id == id && delivery.task_id == id && participants_admitted?
          raise RelayDelivery::LostFence
        end
        @confirming_native_observation = true
        update!(execution_route: "native")
      end
    end
  ensure
    @confirming_native_observation = false
  end

  # A2A §3.1.1: a verified Message-only result has no Task to complete.
  # Remove just the provisional ledger object, preserving its accepted receipt.
  def retire_message_tracking!(delivery:, holder:, fence:)
    delivery.with_lock do
      with_lock do
        message = delivery.result_payload&.fetch("message", nil)
        unless held? && relay_task.nil? && artifacts.empty? && events.empty? &&
            delivery.execution_route == "native" && delivery.operation == "SendMessage" &&
            delivery.phase == "accepted" && !delivery.expired_at? &&
            delivery.holder == holder && delivery.fence == fence && delivery.task_id == id &&
            delivery.reserved_task_id == id && message.is_a?(Hash) && !message.key?("taskId") &&
            relay_deliveries.where.not(id: delivery.id).none? && participants_admitted?
          raise RelayDelivery::LostFence
        end
        A2a::NativeResult.validate_message!(message)
        @retiring_message_tracking = true
        destroy!
      end
    end
  ensure
    @retiring_message_tracking = false
  end

  def ensure_inbox!
    raise NotInbox unless inbox?
  end

  def participants_admitted?
    ids = [ caller_agent_id, recipient_agent_id ].uniq
    organization.agents.admitted.where(id: ids).count == ids.size
  end

  # Only the newest causal input can fence a reply. Legacy or broken bindings
  # fail closed; neither history order nor timestamps establish this evidence.
  def latest_caller_input
    return unless Concourse.v3? && inbox?
    event = events.where(kind: "caller_input").reorder(id: :desc).skip_query_cache!.first
    binding = event&.payload
    return unless binding.is_a?(Hash) && binding["message_id"].is_a?(String) && binding["message_id"].present?
    message = messages.where(message_id: binding["message_id"], role: "ROLE_USER", sender_agent_id: caller_agent_id).skip_query_cache!.first
    return unless message && message.wire_message_id.is_a?(String) && message.wire_message_id.present?

    { "cursor" => event.id.to_s, "messageId" => message.wire_message_id }
  end

  def mark_content_changed!
    update_columns(content_changed_at: Time.current)
  end

  def input_delivery_unconfirmed?
    (held? && relay_task.nil?) || relay_deliveries.where(phase: "held", operation: "SendMessage").exists?
  end

  # The owner pages' "waiting on you": tasks that cannot move until one of
  # this person's agents acts, oldest first. Two cases, the same rules as
  # next_task and Task#actionable?:
  # - sent to my agent, and SUBMITTED, or INPUT_REQUIRED that the caller has
  #   since answered;
  # - sent by my agent, and paused for input or authorization that my agent
  #   has not yet answered.
  NEWER_CALLER_MESSAGE = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1 FROM messages
      WHERE messages.task_id = tasks.id
        AND messages.role = 'ROLE_USER'
        AND (
          (tasks.execution_route = 'inbox' AND messages.created_at > tasks.status_at)
          OR (tasks.execution_route != 'inbox' AND messages.native_after_sequence >= COALESCE(
            (SELECT MAX(task_events.id) FROM task_events WHERE task_events.task_id = tasks.id AND task_events.kind IN ('status', 'snapshot_boundary') AND task_events.settlement_evidence = 1), 1))
        )
    )
  SQL

  # A2A §3.2.2: caller input answers the authored question, not a later
  # restatement of it. Causal event IDs also work when clocks are equal.
  V3_INPUT_BOUNDARY = <<~SQL.squish.freeze
    CASE WHEN tasks.state IN ('TASK_STATE_INPUT_REQUIRED', 'TASK_STATE_AUTH_REQUIRED')
      AND tasks.status_message_id IS NOT NULL THEN COALESCE(
        (SELECT MIN(task_events.id) FROM task_events WHERE task_events.task_id = tasks.id
          AND task_events.state IS NOT NULL AND task_events.status_message_id = tasks.status_message_id),
        (SELECT MAX(task_events.id) FROM task_events WHERE task_events.task_id = tasks.id AND task_events.state IS NOT NULL), 0)
      ELSE COALESCE((SELECT MAX(task_events.id) FROM task_events
        WHERE task_events.task_id = tasks.id AND task_events.state IS NOT NULL), 0) END
  SQL
  V3_NEWER_CALLER_MESSAGE = <<~SQL.squish.freeze
    ((tasks.execution_route = 'inbox' AND EXISTS (SELECT 1 FROM task_events
      WHERE task_events.task_id = tasks.id AND task_events.kind = 'caller_input'
        AND task_events.id > (#{V3_INPUT_BOUNDARY})))
      OR (tasks.execution_route != 'inbox' AND (#{NEWER_CALLER_MESSAGE})))
  SQL
  V3_RECIPIENT_WAITING = <<~SQL.squish.freeze
    tasks.execution_route = 'inbox' AND (
      (tasks.state = 'TASK_STATE_SUBMITTED' AND EXISTS (SELECT 1 FROM messages
        WHERE messages.task_id = tasks.id AND messages.role = 'ROLE_USER'
          AND messages.sender_agent_id = tasks.caller_agent_id))
      OR (#{V3_NEWER_CALLER_MESSAGE}))
  SQL

  def self.awaiting_owner(owner)
    ids = owner.agents.select(:id)
    as_recipient = inbox.where(recipient_agent_id: ids)
    as_recipient = if Concourse.v3?
      as_recipient.unfinished.where(V3_RECIPIENT_WAITING)
    else
      as_recipient.where("tasks.state = 'TASK_STATE_SUBMITTED' OR (tasks.state = 'TASK_STATE_INPUT_REQUIRED' AND #{NEWER_CALLER_MESSAGE})")
    end
    newer = Concourse.v3? ? V3_NEWER_CALLER_MESSAGE : NEWER_CALLER_MESSAGE
    as_caller = where(caller_agent_id: ids, state: INTERRUPTED_STATES).where("NOT (#{newer})")
      .where.not(id: RelayDelivery.where(phase: "held", operation: "SendMessage").where.not(task_id: nil).select(:task_id)) # tenancy-ok: IDs only; never exposes receipt data
      .where("tasks.execution_route != 'held' OR EXISTS (SELECT 1 FROM relay_tasks WHERE relay_tasks.task_id = tasks.id)")
    as_caller = as_caller.where("NOT (#{V3_RECIPIENT_WAITING})") if Concourse.v3?
    as_recipient.or(as_caller)
  end

  # Whether this task is waiting on the owner, by the same rules.
  def awaiting?(owner)
    side = waiting_side
    side.present? && agent_on(side).owner_id == owner.id
  end

  # The side that has to act next, or nil when the task is moving or done.
  def waiting_side
    return "recipient" if actionable?
    "caller" if !input_delivery_unconfirmed? && interrupted? && !caller_answered?
  end

  # What a person calls the task: the first line of the caller's first text
  # part. Message content, so it never reaches a log or an event.
  def headline
    first = messages.select { |message| message.role == "ROLE_USER" }.min_by(&:created_at)
    text = Array(first&.parts).filter_map { |part| part["text"] if part.is_a?(Hash) }.first
    text.to_s.strip.lines.first.to_s.strip.truncate(140).presence
  end

  def terminal?
    TERMINAL_STATES.include?(state)
  end

  def interrupted?
    INTERRUPTED_STATES.include?(state)
  end

  def caller_answered?
    if Concourse.v3? && inbox?
      return organization.tasks.where(id: id).where(V3_NEWER_CALLER_MESSAGE).exists?
    end
    return messages.any? { |message| message.role == "ROLE_USER" && message.created_at > status_at } if inbox?

    sequence = events.where(kind: %w[status snapshot_boundary], settlement_evidence: true).maximum(:id)
    sequence && messages.any? { |message| message.role == "ROLE_USER" && message.native_after_sequence && message.native_after_sequence >= sequence }
  end

  # SUBMITTED is waiting on the recipient. INPUT_REQUIRED is waiting again
  # only after the caller has sent a message newer than the status that asked.
  def actionable?
    return false unless inbox?
    if Concourse.v3?
      return !terminal? && organization.tasks.where(id: id).where(V3_RECIPIENT_WAITING).exists?
    end
    return true if state == "TASK_STATE_SUBMITTED"
    return false unless state == "TASK_STATE_INPUT_REQUIRED"

    caller_answered?
  end

  def actionable_since
    return status_at if state == "TASK_STATE_SUBMITTED"
    if Concourse.v3? && inbox?
      boundary = interrupted? && status_message_id && events.where(status_message_id: status_message_id).where.not(state: nil).minimum(:id)
      boundary ||= events.where.not(state: nil).maximum(:id) || 0
      return events.where(kind: "caller_input").where("id > ?", boundary).minimum(:created_at)
    end

    messages.select { |message| message.role == "ROLE_USER" && message.created_at > status_at }.map(&:created_at).min
  end

  def unclaimed_caller_messages
    claimed = task_deliveries.joins(:task_delivery_messages).select("task_delivery_messages.message_id")
    messages.where(role: "ROLE_USER", sender_agent_id: caller_agent_id).where.not(message_id: claimed)
  end

  # Restrict validated reply evidence to its own status write, even when that write raises.
  def with_reply_output(output)
    previous = @reply_output
    @reply_output = output
    yield
  ensure
    @reply_output = previous
  end

  # Only the recipient may move a task, and a terminal state has no outgoing
  # edge. The specification does not publish a graph among the non-terminal
  # states, so any of those may move to any other stored state.
  # TASK_STATE_UNSPECIFIED is the proto zero value and is not stored.
  def transition_to!(new_state, by:, status_message: nil)
    ensure_inbox!
    raise NotRecipient unless by&.id == recipient_agent_id
    raise Terminal if terminal?
    raise InvalidTransition, "unknown state" unless STATES.include?(new_state)
    raise InvalidTransition, "not a transition" if new_state == state

    attrs = { state: new_state, status_at: Time.current }
    attrs[:status_message_id] = status_message.message_id if status_message
    # The state and the caller's event commit together.
    transaction do
      update!(attrs)
      AgentEvent.state_changed!(self, by: by)
    end
    true
  end

  # A new status in the same state: the recipient said something (a message
  # or an artifact) without moving the task. Its timestamp moves, so a caller
  # watching ListTasks with statusTimestampAfter sees the update. A message
  # given here becomes the status message; without one the old one stays.
  def restate!(by:, status_message: nil)
    ensure_inbox!
    raise NotRecipient unless by&.id == recipient_agent_id
    raise Terminal if terminal?

    attrs = { status_at: Time.current }
    attrs[:status_message_id] = status_message.message_id if status_message
    update!(attrs)
    record_status_event if Concourse.v3? && !status_changed_for_event?
  end

  # CancelTask is the caller's operation, not the recipient's.
  # §3.1.5 lists TaskNotCancelableError for a task that is already canceled.
  # §3.3.1 says CancelTask is idempotent: a duplicate cancellation has the
  # same effect. Those two disagree. A second cancel of a task this caller
  # already canceled returns the task; any other terminal state is
  # TaskNotCancelableError.
  def cancel_by_caller!(by:)
    with_lock do
      ensure_inbox!
      raise NotCaller unless by&.id == caller_agent_id && participants_admitted?
      return self if state == "TASK_STATE_CANCELED"
      raise InvalidTransition, "not cancelable" if terminal?
      if Concourse.v3?
        raise InvalidTransition, "execution may have started" if task_deliveries.where(phase: %w[prompting running uncertain]).exists? || state == "TASK_STATE_WORKING"
        task_deliveries.where(phase: "queued").update_all(phase: "canceled", updated_at: Time.current)
      end
      update!(state: "TASK_STATE_CANCELED", status_at: Time.current, status_message_id: nil)
      AgentEvent.state_changed!(self, by: by)
    end
  end

  private

  def status_changed_for_event?
    inbox? && (saved_change_to_status_at? || (Concourse.v3? && (saved_change_to_state? || saved_change_to_status_message_id?)))
  end

  # A new status that leaves the task waiting on one side: SUBMITTED waits on
  # the recipient, an interrupted state on the caller. OwnerAlertJob runs
  # after a grace period and alerts only if nothing has moved since.
  def waiting_on_a_person?
    saved_change_to_status_at? && PushSubscription.configured? && waiting_side.present? && participants_admitted?
  end

  def schedule_owner_alert
    return unless PushSubscription.where(user_id: [ caller_agent.owner_id, recipient_agent.owner_id ]).exists?

    OwnerAlertJob.set(wait: OwnerAlertJob::GRACE).perform_later(organization_id, id, status_at.utc.iso8601(6))
  end

  # Every new status is an event, whichever of create, transition_to!,
  # restate!, or cancel_by_caller! made it.
  def record_status_event
    events.create!(state: state, status_message_id: status_message_id, created_at: status_at,
      kind: ("reply" if @reply_output), payload: @reply_output ? { "concourse.output" => @reply_output } : {})
  end

  # No task crosses organizations: both agents are in the one it is sent in.
  def agents_share_the_organization
    agents = [ recipient_agent, caller_agent ].compact
    errors.add(:base, :across_organizations) if agents.any? { |agent| agent.organization_id != organization_id }
  end

  def immutable_execution_route
    proven_classification = @confirming_native_observation && execution_route_in_database == "held" && execution_route == "native"
    errors.add(:execution_route, "cannot change executor") if will_save_change_to_execution_route? && !proven_classification
  end

  def track_inbox_content
    if new_record? || (inbox? && (will_save_change_to_state? || will_save_change_to_status_at?))
      self.content_changed_at = Time.current
    end
  end

  def expire_delivery_fences
    relay_deliveries.find_each(&:expire!)
  end

  def assign_ids
    self.id ||= SecureRandom.uuid
    self.context_id ||= SecureRandom.uuid
    self.status_at ||= Time.current
  end
end
