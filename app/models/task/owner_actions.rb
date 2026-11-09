# The owner pages acting on a task as one of the signed-in person's own
# agents. A person is their agent's principal, so a reply typed on the web is
# that agent's reply: it goes through A2a::Exchange like every other
# transport, under the same caller and recipient rules, and the message
# carries concourse.via = "owner" so the other side can tell a person wrote it.
module Task::OwnerActions
  extend ActiveSupport::Concern

  SIDES = %w[recipient caller].freeze
  VIA = "owner".freeze
  # States an owner may move their recipient agent's task to. AUTH_REQUIRED
  # is left to agents: a person on the web has no credential flow to ask for.
  REPLY_STATES = %w[
    TASK_STATE_WORKING
    TASK_STATE_INPUT_REQUIRED
    TASK_STATE_COMPLETED
    TASK_STATE_REJECTED
    TASK_STATE_FAILED
  ].freeze

  # Which sides of this task the owner holds. Both, when they sent a task
  # from one of their agents to another.
  def sides_for(owner)
    SIDES.select { |side| agent_on(side).owner_id == owner.id }
  end

  def agent_on(side)
    side.to_s == "caller" ? caller_agent : recipient_agent
  end

  # As recipient: an agent message, a new state, or both (Exchange#reply).
  # As caller: a follow-up user message on the same task (SendMessage with a
  # taskId, §3.1.1), which is how a caller answers INPUT_REQUIRED.
  def respond_for_owner!(owner, side:, text:, state: nil)
    agent = owned_agent!(owner, side)
    text = text.to_s.strip

    message = if side.to_s == "recipient"
      respond_as_recipient(agent, text, state)
    else
      respond_as_caller(agent, text)
    end
    message&.update!(metadata: message.metadata.merge("concourse.via" => VIA)) if inbox?
    Rails.event.notify("concourse.owner.responded", task_id: id, side: side.to_s, state: organization.tasks.find_by(id: id)&.state)
    message
  end

  def cancel_for_owner!(owner)
    agent = owned_agent!(owner, "caller")
    A2a::Exchange.cancel_task(caller: agent, recipient: recipient_agent, id: id)
    Rails.event.notify("concourse.owner.canceled", task_id: id)
  end

  private

  def owned_agent!(owner, side)
    raise A2a::Error.new(:invalid_params) unless SIDES.include?(side.to_s)
    raise A2a::Error.new(:unsupported_operation) unless sides_for(owner).include?(side.to_s)

    agent_on(side)
  end

  def respond_as_recipient(agent, text, state)
    raise A2a::Error.new(:unsupported_operation) unless inbox?
    state = nil if state.blank? || state == self.state
    raise A2a::Error.new(:invalid_params) if state && !REPLY_STATES.include?(state)
    raise A2a::Error.new(:invalid_params) if text.empty? && state.nil?

    task = A2a::Exchange.reply(agent: agent, task_id: id, parts: text.presence && [ { "text" => text } ], state: state, owner: Concourse.v3? ? Current.user : nil)
    task.status_message if text.present?
  end

  def respond_as_caller(agent, text)
    raise A2a::Error.new(:unsupported_operation) if input_delivery_unconfirmed?
    raise A2a::Error.new(:invalid_params) if text.empty?

    message_id = SecureRandom.uuid
    A2a::Exchange.send_message(
      caller: agent,
      recipient: recipient_agent,
      message: { "role" => "ROLE_USER", "messageId" => message_id, "taskId" => id, "parts" => [ { "text" => text } ] },
      configuration: { "returnImmediately" => true },
      via: VIA
    )
    Message.find_by(sender_agent: agent, client_message_id: message_id) # tenancy-ok: the sender is this task's own agent
  end
end
