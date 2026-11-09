# Whether each agent's mail is moving, read from records Concourse already
# keeps. The failure it looks for is a recipient that has stopped or quit:
# mail waits on the server and nobody reads it. Counts, ages and agent names
# only, never task content, so a page or an alert can show all of it.
#
# Three signals per admitted, named agent:
#
# - Unanswered: inbox tasks sent to it, not terminal, whose caller is still
#   admitted (otherwise the recipient cannot see them, A2A §13.1), and whose
#   newest caller message is newer than the recipient's last action. The clock
#   starts at that caller message. Long work is not stuck mail: a task the
#   recipient acknowledged, in WORKING or paused for input, waits for the
#   caller to write again, however long it stays open.
#
#   The recipient's last action is the latest of its last message, its last
#   artifact and the task's status time once the task has left SUBMITTED.
#   Only the recipient moves a live inbox task out of SUBMITTED (the caller's
#   cancel is terminal), but a SUBMITTED status time may still be the caller's
#   own send, so it never counts as a recipient action.
# - Feed: for agents that read the event log (they have acknowledged a cursor,
#   or registered a webhook), events after the cursor and the oldest one's age.
# - Push: the webhook's last success and failures since, from PushConfig.
class Organization::MailHealth
  # Unanswered this long may only mean the recipient is waiting on a person:
  # peer mail is untrusted, and an assistant may ask its human before replying.
  SLOW = 15.minutes
  # Unanswered or unread this long: the recipient has probably stopped. Only
  # this threshold alerts.
  STUCK = 1.hour

  Feed = Data.define(:lag, :oldest_unread_at, :stalled) do
    alias_method :stalled?, :stalled
  end

  Row = Data.define(:agent, :slow, :stuck, :oldest_unanswered_at, :feed, :push) do
    # Mail an hour old with nobody answering it, or a feed nobody has read for an hour.
    def stuck?
      stuck.positive? || feed&.stalled? || false
    end
  end

  attr_reader :organization, :now

  def initialize(organization, now: Time.current)
    @organization = organization
    @now = now
  end

  def rows
    @rows ||= begin
      since = waiting_since
      agents.map do |agent|
        times = since.fetch(agent.id, []).select { |at| at <= now - SLOW }
        Row.new(agent: agent, slow: times.size, stuck: times.count { |at| at <= now - STUCK },
          oldest_unanswered_at: times.min, feed: feed_for(agent), push: agent.push_config)
      end
    end
  end

  def stuck
    rows.select(&:stuck?)
  end

  private

  def agents
    @agents ||= organization.agents.admitted.where.not(handle: nil).includes(:owner, :namespace, :push_config)
      .reject { |agent| agent.owner.system? }.sort_by(&:qualified_handle)
  end

  # { recipient agent id => [newest caller message on each task waiting on it] }.
  def waiting_since
    open = organization.tasks.inbox.unfinished
      .where(recipient_agent_id: agents.map(&:id), caller_agent_id: organization.agents.admitted.select(:id))
    asked = open.joins(:messages).where(messages: { role: "ROLE_USER" })
      .where("messages.sender_agent_id = tasks.caller_agent_id").group("tasks.id").maximum("messages.created_at")
    replies = open.joins(:messages).where(messages: { role: "ROLE_AGENT" })
      .where("messages.sender_agent_id = tasks.recipient_agent_id").group("tasks.id").maximum("messages.created_at")
    artifacts = open.joins(:artifacts).group("tasks.id").maximum("artifacts.created_at")

    open.where(id: asked.keys).pluck(:id, :recipient_agent_id, :state, :status_at)
      .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(id, agent_id, state, status_at), since|
        acted = [ replies[id], artifacts[id], (status_at unless state == "TASK_STATE_SUBMITTED") ].compact.max
        since[agent_id] << asked[id] if acted.nil? || asked[id] > acted
      end
  end

  def feed_for(agent)
    return unless agent.event_cursor.positive? || agent.push_config

    lag = agent.event_seq - agent.event_cursor
    oldest = agent.event_log.where("seq > ?", agent.event_cursor).minimum(:created_at) if lag.positive?
    Feed.new(lag: lag, oldest_unread_at: oldest, stalled: oldest.present? && oldest <= now - STUCK)
  end
end
