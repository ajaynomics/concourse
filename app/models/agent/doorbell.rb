class Agent::Doorbell
  def self.open(agent, session_id: nil)
    if session_id && (!Concourse.v3? || !session_id.is_a?(String) || !Agent::Connection::SESSION_FORMAT.match?(session_id))
      raise A2a::Error.new(:invalid_params)
    end
    return unless acquired = A2a::Waiters.acquire(agent.organization_id)

    stream = new(agent)
    stream.attach(session_id) if session_id
    stream
  rescue StandardError
    # Database/cable initialization can fail before there is a Rack body
    # responsible for close. Release its capacity without hiding the failure.
    if stream
      stream.close
    elsif acquired
      A2a::Waiters.release(agent.organization_id)
    end
    raise
  end

  def attach(session_id)
    @connection = Agent::Connection.open!(@agent, session_id: session_id)
  end

  def initialize(agent)
    @agent = agent
    @organization_id = agent.organization_id
    @stream = "agent_doorbell:#{agent.id}"
    # Bounded and nonblocking on the cable thread. A lost hint is safe because
    # ready/reconnect and the client's backstop always re-read the mailbox.
    @queue = SizedQueue.new(256)
    @callback = ->(message) { enqueue(message) }
    @pubsub = ActionCable.server.pubsub
  end

  # Rack's streaming body ABI, like the A2A SSE binding under Falcon. Queue
  # pop uses Ruby's fiber scheduler; the cable callback only enqueues bytes,
  # never writes into another fiber's response or borrows its DB connection.
  def call(io)
    each { |frame| io.write(frame) }
  rescue *A2a::Rpc::CLIENT_LEFT
    # Disconnects do not consume or cancel mailbox work.
  ensure
    close
    io.close
  end

  def each
    deadline = monotonic + A2a::Exchange.stream_limit
    heartbeat_at = monotonic + A2a::Exchange.heartbeat_interval
    @subscribed = true
    @pubsub.subscribe(@stream, @callback, -> { enqueue(:ready) })
    while !@closed && monotonic < deadline
      return unless accessible?
      ActiveRecord::Base.connection_pool.release_connection unless ActiveRecord::Base.connection.transaction_open?
      timeout = [ deadline - monotonic, heartbeat_at - monotonic ].min.clamp(0, A2a::Exchange.heartbeat_interval)
      message = @queue.pop(timeout: timeout)
      return unless accessible?
      if message == :ready
        ready = @connection ? JSON.generate(release_line: 3, connectionId: @connection.id, sessionId: @connection.session_id) : ""
        yield "event: ready\ndata:#{ready.empty? ? "" : " #{ready}"}\n\n"
      elsif message
        ping = JSON.parse(message)
        if ping["reason"].in?(%w[inbox reply]) && Task.visible_to(@agent).inbox.exists?(ping["taskId"])
          yield "event: ping\ndata: #{JSON.generate(ping.slice("reason", "taskId"))}\n\n"
        end
      end
      if monotonic >= heartbeat_at
        return if @connection && !@connection.renew!
        yield ": keepalive\n\n"
        heartbeat_at = monotonic + A2a::Exchange.heartbeat_interval
      end
    end
  ensure
    close
    ActiveRecord::Base.connection_pool.release_connection
  end

  def close
    return if @closed
    @closed = true
    @pubsub.unsubscribe(@stream, @callback) if @subscribed
    @connection&.close!
  ensure
    if @closed && !@released
      @released = true
      A2a::Waiters.release(@organization_id)
    end
  end

  private

  def enqueue(message)
    @queue.push(message, true)
  rescue ThreadError
    # The mailbox, not this hint buffer, is the durable queue.
  end

  def accessible?
    return false if @connection && !@connection.active?
    Agent.uncached { @agent.organization.agents.admitted.exists?(id: @agent.id, organization_id: @organization_id) }
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
