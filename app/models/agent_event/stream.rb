# The event log as Server-Sent Events: `ready`, then each event with its seq
# as the SSE id so a reconnect resumes with Last-Event-ID, a keepalive
# comment when quiet, and `bye` at the stream limit. Like Agent::Doorbell it
# is a Rack streaming body and holds one A2a::Waiters slot, so waiting
# streams stay bounded and no organization crowds out another. It reads the
# log; it never acknowledges, so an event the client did not process is sent
# again after it reconnects.
class AgentEvent::Stream
  def self.open(agent, after:)
    return new(agent, after) if A2a::Waiters.acquire(agent.organization_id)

    Rails.event.notify("concourse.a2a.waiter_cap", kind: "events_stream", limit: A2a::Waiters.limit)
    nil
  end

  def initialize(agent, cursor)
    @agent = agent
    @cursor = cursor
    @organization_id = agent.organization_id
  end

  def call(io)
    each { |frame| io.write(frame) }
  rescue *A2a::Rpc::CLIENT_LEFT
    # The client left. Its events stay in the log for the next connection.
  rescue StandardError => exception
    # Headers are sent, so the connection just ends and the client resumes.
    Rails.error.report(exception, handled: true, context: { source: "agent_events.stream" })
  ensure
    close
    io.close
  end

  def each
    yield frame("ready", { "cursor" => @cursor, "oldest" => AgentEvent.oldest_kept(@agent) })
    deadline = monotonic + A2a::Exchange.stream_limit
    quiet_since = monotonic
    while monotonic < deadline
      # Removal ends observation (A2A §13.1) even for a stream already open.
      return unless accessible?

      page = AgentEvent.page(@agent, after: @cursor)
      page.events.each { |event| yield frame(event["type"], event, id: event["id"]) }
      @cursor = page.cursor
      quiet_since = monotonic if page.events.any?
      next if page.more

      if monotonic - quiet_since >= A2a::Exchange.heartbeat_interval
        yield ": keepalive\n\n"
        quiet_since = monotonic
      end
      A2a::Waiters.idle([ A2a::Exchange.poll_interval, deadline - monotonic ].min.clamp(0, nil))
    end
    yield frame("bye", { "reason" => "limit" })
  ensure
    close
    # The body runs in its own fiber, which would otherwise keep its last connection.
    ActiveRecord::Base.connection_pool.release_connection
  end

  def close
    return if @closed

    @closed = true
    A2a::Waiters.release(@organization_id)
  end

  private

  def accessible?
    AgentEvent.uncached { @agent.admitted? }
  end

  def frame(event, data, id: nil)
    "#{"id: #{id}\n" if id}event: #{event}\ndata: #{JSON.generate(data)}\n\n"
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
