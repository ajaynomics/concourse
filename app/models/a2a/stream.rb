module A2a
  # What a streaming call sends (§3.1.2, §3.1.6): the task as it stands, then
  # each event recorded after that, in order, until the task is terminal. A
  # Message answer is the whole stream. The binding frames each
  # StreamResponse; this decides what they are and when.
  class Stream
    # A stream outlives Cloudflare's 100 seconds only while bytes flow, so an
    # idle one sends a comment this often. One that has followed a task this
    # long ends, and the caller subscribes again.
    HEARTBEAT = 15
    LIMIT = 15.minutes.to_i

    def self.message(direct_message, viewer:, recipient:, delivery_id: nil)
      new(first: { "message" => direct_message.to_h }, viewer: viewer, recipient: recipient, delivery_id: delivery_id)
    end

    # The task and the cursor are read in one transaction, so no event is
    # both in the task and sent after it, and none falls between them.
    def self.task(task, history_length: nil, viewer: nil)
      Task.transaction do
        Task.uncached do
          cursor = task.events.maximum(:id) || 0
          task.reload
          new(first: { "task" => Serializer.task(task, history_length: history_length) }, task: task, cursor: cursor, viewer: viewer)
        end
      end
    end

    def initialize(first:, task: nil, cursor: nil, viewer: nil, recipient: nil, delivery_id: nil)
      @first = first
      @task = task
      @cursor = cursor
      @viewer = viewer
      @recipient, @delivery_id = recipient, delivery_id
    end

    # Yields each StreamResponse, and nil whenever the heartbeat interval
    # passes with nothing to send, so the binding can keep an idle connection
    # open. Ends at a terminal state; at the stream limit, or at once when
    # the waiter cap is full, it ends early, and SubscribeToTask picks up
    # from the task as it then stands.
    def each
      return unless accessible?
      yield @first
      return if @task.nil? || Task::TERMINAL_STATES.include?(@first.dig("task", "status", "state"))
      unless Waiters.acquire(waiter_key)
        Rails.event.notify("concourse.a2a.waiter_cap", kind: "stream", limit: Waiters.limit)
        return
      end

      begin
        deadline = monotonic + Exchange.stream_limit
        quiet_since = monotonic
        while monotonic < deadline
          # Either participant's removal ends observation (§13.1), not just
          # removal of the viewer. It does not cancel upstream effects.
          return unless accessible?

          events = TaskEvent.uncached { @task.events.where(id: (@cursor + 1)..).order(:id).includes(:status_message, :artifact).to_a }
          events.each do |event|
            return unless accessible?
            # A fresh snapshot changes the artifact/history base (§4.2.2).
            # Close before new-base events; a subscription gets one new Task.
            raise RelayError.new("RELAY_SNAPSHOT_BOUNDARY", task_id: @task.id) if event.kind == "snapshot_boundary"
            @cursor = event.id
            # Internal v3 caller-input observations advance the cursor, not A2A status (§3.5.2).
            next if event.kind == "caller_input"
            yield update(event)
            return if !event.artifact? && Task::TERMINAL_STATES.include?(event.state)
          end
          quiet_since = monotonic if events.any? { |event| event.kind != "caller_input" }
          if monotonic - quiet_since >= Exchange.heartbeat_interval
            yield nil
            quiet_since = monotonic
          end
          Waiters.idle(Exchange.poll_interval)
        end
      ensure
        Waiters.release(waiter_key)
        # The body runs in its own fiber, which would otherwise keep its
        # last connection until the pool reaped it.
        ActiveRecord::Base.connection_pool.release_connection
      end
    end

    private

    def accessible?
      # The Rack body can outlive its request's query cache. Removal/expiry
      # from another process must revoke the next disclosure (A2A §13.1).
      Task.uncached do
        unless @task
          return false unless @viewer && @recipient && @viewer.organization_id == @recipient.organization_id
          organization = @viewer.organization
          ids = [ @viewer.id, @recipient.id ].uniq
          return false unless organization.agents.admitted.where(id: ids).count == ids.size
          return !@delivery_id || organization.relay_deliveries.where(caller_agent_id: @viewer.id,
            recipient_agent_id: @recipient.id, expired_at: nil).exists?(@delivery_id)
        end
        return false if @viewer && !Task.visible_to(@viewer).exists?(@task.id)
        return false unless Task.exists?(@task.id) # tenancy-ok: already scoped stream, existence only

        ids = [ @task.caller_agent_id, @task.recipient_agent_id ].uniq
        @task.organization.agents.admitted.where(id: ids).count == ids.size
      end
    end

    def waiter_key
      @viewer&.organization_id || @task&.organization_id
    end

    def update(event)
      if event.payload && event.kind.in?(%w[status artifact])
        key = event.kind == "artifact" ? "artifactUpdate" : "statusUpdate"
        return { key => event.payload.deep_dup }
      end

      if event.artifact?
        # Concourse records whole artifacts, so each is its own last chunk.
        { "artifactUpdate" => ids.merge("artifact" => Serializer.artifact(event.artifact), "lastChunk" => true) }
      else
        update = ids.merge("status" => Serializer.status(event))
        # A2A v1.0 §4.2.1: status-only replies carry evidence on the event, not TaskStatus.
        binding = event.reply_metadata(task: @task)
        update["metadata"] = { "concourse.reply_to" => binding } if binding
        { "statusUpdate" => update }
      end
    end

    def ids
      { "taskId" => @task.id, "contextId" => @task.context_id }
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
