# What an agent's peers did on tasks it is party to, in order: a message, a
# state change, an artifact. One row per event per hearing agent, so an agent
# never hears about its own actions and a read costs the new events, not the
# number of open tasks.
#
# seq is the agent's cursor. It is assigned inside the transaction that
# writes the message, state or artifact, and SQLite has one writer, so rows
# become visible in seq order and a cursor never skips a late commit.
# agents.event_seq counts what was assigned, so no number is handed out twice.
# Numbers are not dense once retention runs: rows leave with their task, so a
# purge can remove ids anywhere in the log. Only a hole before the oldest
# kept row is detected (CursorExpired); `oldest` lets a client see it.
#
# The log holds references, not copies. A row names its message or artifact
# and the wire form is built on read. A read never loads more content than a
# page may carry: sizes come from SQL, and parts or metadata over the event
# limits are replaced there by empty values, so they never reach Ruby.
#
# Only v3 inbox tasks write here; release line 1 and native/held tasks are
# untouched. The log starts at deploy: older work is read through the task API.
class AgentEvent < ApplicationRecord
  KINDS = %w[message state artifact].freeze

  PAGE_LIMIT = 100
  PAGE_BYTES = 1.megabyte
  # A message or artifact whose parts exceed this is sent without them and
  # flagged truncated; the client reads the task for the whole content.
  PARTS_BYTES = 64.kilobytes
  # With parts gone, an event still carrying huge metadata is cut to its identifiers.
  EVENT_BYTES = 256.kilobytes
  # What an event's metadata, extensions and the like may add to its parts.
  EXTRA_BYTES = EVENT_BYTES - PARTS_BYTES
  # Serialized envelope, identifiers and sender label, assumed when budgeting a page.
  ENVELOPE_BYTES = 2.kilobytes
  WAIT_LIMIT = 25
  RETRY_AFTER = "30"
  CURSOR_FORMAT = /\A[0-9]{1,18}\z/
  # The hint a sender may attach is slice 2 work. Every message is handled in order.
  DELIVERY = "queue"
  NO_BINDINGS = { "messages" => {}, "artifacts" => {} }.freeze
  IDENTIFIERS = { "message" => %w[messageId contextId taskId role], "artifact" => %w[artifactId name] }.freeze

  # Stored byte sizes (SQLite octet_length reads the record header, not the
  # value). Message and artifact content is only ever selected through these.
  MESSAGE_PARTS_SQL = "COALESCE(octet_length(messages.parts), 0)".freeze
  MESSAGE_EXTRA_SQL = "(#{%w[metadata extensions reference_task_ids].map { |column| "COALESCE(octet_length(messages.#{column}), 0)" }.join(" + ")})".freeze
  ARTIFACT_PARTS_SQL = "COALESCE(octet_length(artifacts.parts), 0)".freeze
  ARTIFACT_EXTRA_SQL = "(#{%w[metadata extensions name description].map { |column| "COALESCE(octet_length(artifacts.#{column}), 0)" }.join(" + ")})".freeze
  SIZES_SQL = "#{MESSAGE_PARTS_SQL} AS message_parts_bytes, #{MESSAGE_EXTRA_SQL} AS message_extra_bytes, " \
    "#{ARTIFACT_PARTS_SQL} AS artifact_parts_bytes, #{ARTIFACT_EXTRA_SQL} AS artifact_extra_bytes".freeze
  MESSAGE_CONTENT_SQL = [
    "CASE WHEN #{MESSAGE_PARTS_SQL} > #{PARTS_BYTES} THEN '[]' ELSE messages.parts END AS parts",
    "CASE WHEN #{MESSAGE_EXTRA_SQL} > #{EXTRA_BYTES} THEN '{}' ELSE messages.metadata END AS metadata",
    "CASE WHEN #{MESSAGE_EXTRA_SQL} > #{EXTRA_BYTES} THEN '[]' ELSE messages.extensions END AS extensions",
    "CASE WHEN #{MESSAGE_EXTRA_SQL} > #{EXTRA_BYTES} THEN '[]' ELSE messages.reference_task_ids END AS reference_task_ids",
    "#{MESSAGE_PARTS_SQL} AS parts_bytes", "#{MESSAGE_EXTRA_SQL} AS extra_bytes"
  ].freeze
  ARTIFACT_CONTENT_SQL = [
    "CASE WHEN #{ARTIFACT_PARTS_SQL} > #{PARTS_BYTES} THEN '[]' ELSE artifacts.parts END AS parts",
    "CASE WHEN #{ARTIFACT_EXTRA_SQL} > #{EXTRA_BYTES} THEN '{}' ELSE artifacts.metadata END AS metadata",
    "CASE WHEN #{ARTIFACT_EXTRA_SQL} > #{EXTRA_BYTES} THEN '[]' ELSE artifacts.extensions END AS extensions",
    "CASE WHEN #{ARTIFACT_EXTRA_SQL} > #{EXTRA_BYTES} THEN NULL ELSE artifacts.name END AS name",
    "CASE WHEN #{ARTIFACT_EXTRA_SQL} > #{EXTRA_BYTES} THEN NULL ELSE artifacts.description END AS description",
    "#{ARTIFACT_PARTS_SQL} AS parts_bytes", "#{ARTIFACT_EXTRA_SQL} AS extra_bytes"
  ].freeze

  class CursorInvalid < StandardError; end

  class CursorExpired < StandardError
    attr_reader :oldest

    def initialize(oldest)
      @oldest = oldest
      super("cursor expired")
    end
  end

  # No waiting slot free (A2a::Waiters), so a long poll or stream cannot start.
  class Capacity < StandardError; end

  Page = Data.define(:events, :cursor, :more)

  belongs_to :agent
  belongs_to :task
  belongs_to :message, primary_key: :message_id, optional: true
  belongs_to :artifact, primary_key: :artifact_id, optional: true

  validates :kind, inclusion: { in: KINDS }
  before_update -> { throw :abort }
  after_create_commit { PushNotificationJob.perform_later(agent.organization_id, id) if agent.push_config }

  class << self
    def limits
      { "page_max" => PAGE_LIMIT, "page_bytes" => PAGE_BYTES, "part_bytes" => PARTS_BYTES,
        "wait_max" => WAIT_LIMIT, "stream_seconds" => A2a::Stream::LIMIT, "heartbeat_seconds" => A2a::Stream::HEARTBEAT }
    end

    # The peer hears what the sender wrote, never the sender.
    def message_created!(message)
      task = message.task
      return unless recordable?(task)

      record(to: peer_of(task, message.sender_agent_id), by: message.sender_agent_id, task: task, kind: "message", message_id: message.message_id)
    end

    # Only the recipient attaches artifacts (Artifact.record!), so the caller hears.
    def artifact_created!(artifact)
      task = artifact.task
      return unless recordable?(task)

      record(to: task.caller_agent, by: task.recipient_agent_id, task: task, kind: "artifact", artifact_id: artifact.artifact_id)
    end

    # The agent that did not change the state hears it.
    def state_changed!(task, by:)
      return unless recordable?(task)

      record(to: peer_of(task, by.id), by: by.id, task: task, kind: "state", state: task.state)
    end

    # The first sequence number a client can still read.
    def oldest(agent, head)
      uncached { agent.event_log.minimum(:seq) } || head + 1
    end

    # What every successful read reports, so a client can see a purge even
    # when its cursor is still 0.
    def oldest_kept(agent)
      head, = counters(agent)
      oldest(agent, head)
    end

    # Where a read starts: after, or the server cursor when the client gave
    # none. A cursor ahead of anything assigned is a client error; one behind
    # purged events is expired. Zero means "from the start of what is kept".
    def resume_point(agent, after)
      head, acknowledged = counters(agent)
      after = acknowledged if after.nil?
      raise CursorInvalid if after > head
      first = oldest(agent, head)
      raise CursorExpired.new(first) if after.positive? && after + 1 < first

      after
    end

    def parse_cursor(value)
      case value
      when Integer then value.negative? || value > 10**18 ? raise(CursorInvalid) : value
      when String then value.match?(CURSOR_FORMAT) ? Integer(value, 10) : raise(CursorInvalid)
      else raise CursorInvalid
      end
    end

    # Cumulative and monotonic: a lower or repeated cursor changes nothing.
    def acknowledge!(agent, cursor)
      head, = counters(agent)
      raise CursorInvalid if cursor > head

      agent.organization.agents.where(id: agent.id).where("event_cursor < ?", cursor).update_all(event_cursor: cursor)
    end

    # Events after a cursor that the agent may still see (A2A §13.1: both
    # participants admitted, the agent party to the task), at most limit and
    # PAGE_BYTES, always at least one when any exist. cursor is the last
    # event examined, which the client sends back as `after`.
    #
    # Memory is bounded by the page, not by the stored content: the first read
    # takes event rows and byte sizes only (at most limit + 1 rows), the page
    # is budgeted from those sizes, and content is then loaded for just the
    # chosen rows with anything over the event limits replaced in SQL.
    def page(agent, after:, limit: PAGE_LIMIT)
      uncached do
        rows = agent.event_log.joins(:task).merge(Task.visible_to(agent))
          .joins("LEFT JOIN messages ON messages.message_id = agent_events.message_id")
          .joins("LEFT JOIN artifacts ON artifacts.artifact_id = agent_events.artifact_id")
          .select("agent_events.*", SIZES_SQL).where(seq: (after + 1)..).order(:seq).limit(limit + 1)
          .preload(task: wire_associations).to_a
        chosen = within_budget(rows.first(limit))
        content = content_for(chosen)
        events = []
        cursor = after
        bytes = 0
        examined = 0
        chosen.each do |row|
          wire = row.to_wire(agent, content)
          size = wire ? JSON.generate(wire).bytesize : 0
          break if events.any? && bytes + size > PAGE_BYTES

          examined += 1
          cursor = row.seq
          next unless wire

          events << wire
          bytes += size
        end
        Page.new(events: events, cursor: cursor, more: examined < rows.size)
      end
    end

    # Messages and artifacts for events, with parts and metadata that exceed
    # the event limits already replaced by empty values and their stored sizes
    # attached, so the content that reaches Ruby never exceeds EVENT_BYTES.
    def content_for(events)
      ids = events.group_by(&:kind).transform_values { |group| group.filter_map { |event| event.message_id || event.artifact_id } }
      light = ->(model, heavy) { (model.column_names - heavy).map { |column| "#{model.table_name}.#{column}" } }
      messages = ids.fetch("message", []).then do |message_ids|
        next {} if message_ids.empty?

        Message.select(*light.(Message, %w[parts metadata extensions reference_task_ids]), *MESSAGE_CONTENT_SQL).where(message_id: message_ids).readonly.index_by(&:message_id) # tenancy-ok: ids come from this agent's visible events
      end
      artifacts = ids.fetch("artifact", []).then do |artifact_ids|
        next {} if artifact_ids.empty?

        Artifact.select(*light.(Artifact, %w[parts metadata extensions name description]), *ARTIFACT_CONTENT_SQL).where(artifact_id: artifact_ids).readonly.index_by(&:artifact_id) # tenancy-ok: ids come from this agent's visible events
      end
      { "message" => messages, "artifact" => artifacts }
    end

    # A long poll: the first page that has events, or an empty page when the
    # wait ends, the agent leaves, or nothing arrives. The slot is released
    # on every path; an empty read never takes one.
    def await(agent, after:, limit: PAGE_LIMIT, wait: 0)
      current = page(agent, after: after, limit: limit)
      return current if current.events.any? || wait <= 0
      unless A2a::Waiters.acquire(agent.organization_id)
        Rails.event.notify("concourse.a2a.waiter_cap", kind: "events", limit: A2a::Waiters.limit)
        raise Capacity
      end

      begin
        deadline = monotonic + wait
        loop do
          return current unless uncached { agent.admitted? }

          remaining = deadline - monotonic
          return current if remaining <= 0

          A2a::Waiters.idle([ A2a::Exchange.poll_interval, remaining ].min)
          current = page(agent, after: after, limit: limit)
          return current if current.events.any?
        end
      ensure
        A2a::Waiters.release(agent.organization_id)
      end
    end

    private

    # Rows that fit a page by the sizes SQL reported, before any content is
    # loaded. The first row always fits, so a page makes progress.
    def within_budget(rows)
      total = 0
      rows.take_while.with_index do |row, index|
        total += estimate(row)
        index.zero? || total <= PAGE_BYTES
      end
    end

    # What a row will add to a page: its content if it will be sent whole,
    # else just identifiers.
    def estimate(row)
      kept = case row.kind
      when "message" then kept_bytes(row[:message_parts_bytes], row[:message_extra_bytes])
      when "artifact" then kept_bytes(row[:artifact_parts_bytes], row[:artifact_extra_bytes])
      else 0
      end
      kept + ENVELOPE_BYTES
    end

    def kept_bytes(parts, extra)
      (parts.to_i > PARTS_BYTES ? 0 : parts.to_i) + (extra.to_i > EXTRA_BYTES ? 0 : extra.to_i)
    end

    # Checked before any agent is loaded, so release line 1 and native tasks pay nothing.
    def recordable?(task)
      Concourse.v3? && task.inbox?
    end

    def record(to:, by:, task:, kind:, **references)
      return unless to && to.id != by && !to.owner.system?

      transaction do
        create!(agent: to, task: task, kind: kind, seq: next_seq(to), **references)
      end
    end

    def peer_of(task, sender_id)
      case sender_id
      when task.caller_agent_id then task.recipient_agent
      when task.recipient_agent_id then task.caller_agent
      end
    end

    # Inside the writer's transaction: the UPDATE takes SQLite's write lock,
    # so the SELECT after it sees exactly this increment.
    def next_seq(agent)
      scope = agent.organization.agents.where(id: agent.id).skip_query_cache!
      scope.update_all("event_seq = event_seq + 1")
      scope.pick(:event_seq)
    end

    def counters(agent)
      uncached { agent.organization.agents.where(id: agent.id).pick(:event_seq, :event_cursor) } || [ 0, 0 ]
    end

    def wire_associations
      [ :organization, { caller_agent: [ :owner, :namespace ] }, { recipient_agent: [ :owner, :namespace ] } ]
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  # Delivered means the hearing agent's acknowledged cursor has reached this
  # event. Not on the wire yet: telling the sender is slice 2.
  def delivered?
    agent.reload.event_cursor >= seq
  end

  # The event as a client reads it, from content AgentEvent.content_for
  # loaded (capped to the event limits). nil when its message or artifact is gone.
  # Messages and artifacts are the A2A objects the task API serializes, without
  # its per-snapshot metadata (concourse.reply_to, concourse.caller).
  def to_wire(viewer, content = nil)
    content ||= AgentEvent.content_for([ self ])
    wire = { "id" => seq, "type" => kind, "task_id" => task_id, "context_id" => task.context_id,
             "at" => A2a::Serializer.timestamp(created_at), "from" => peer(viewer) }
    case kind
    when "message"
      record = content.dig("message", message_id) or return
      record.task = task
      wire["delivery"] = DELIVERY
      wire.merge!(capped("message", A2a::Serializer.message(record, reply_bindings: NO_BINDINGS), record))
    when "artifact"
      record = content.dig("artifact", artifact_id) or return
      wire.merge!(capped("artifact", A2a::Serializer.artifact(record, reply_bindings: NO_BINDINGS), record))
    else
      wire["state"] = state
    end
    wire
  end

  private

  # Only the other participant ever causes an event for the viewer.
  def peer(viewer)
    author = task.caller_agent_id == viewer.id ? task.recipient_agent : task.caller_agent
    { "agent_id" => author.id, "handle" => author.qualified_handle }.compact
  end

  # SQL already emptied what exceeded the limits; this says so, and removes the
  # empty parts key so a client cannot mistake it for a message with none. The
  # size check afterwards is a backstop for serialization overhead.
  def capped(key, payload, record)
    truncated = record[:parts_bytes].to_i > PARTS_BYTES
    payload = payload.except("parts") if truncated
    truncated ||= record[:extra_bytes].to_i > EXTRA_BYTES
    if JSON.generate(payload).bytesize > EVENT_BYTES
      payload = payload.slice(*IDENTIFIERS.fetch(key))
      truncated = true
    end
    truncated ? { key => payload, "truncated" => true } : { key => payload }
  end
end
