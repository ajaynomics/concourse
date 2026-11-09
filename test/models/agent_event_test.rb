require "test_helper"

# Stored bytes of every Message and Artifact a block loads, to prove what a
# read pulls into Ruby. Records only while a test has set the thread-local.
[ Message, Artifact ].each do |model|
  model.after_find do |record|
    Thread.current[:loaded_content]&.push(record.attributes_before_type_cast.values.sum { |value| value.to_s.bytesize })
  end
end

class AgentEventTest < ActiveSupport::TestCase
  setup do
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @organization = Organization.create!(name: "Events", slug: "events")
    @caller = create_agent("caller")
    @recipient = create_agent("recipient")
    @bystander = create_agent("bystander")
    @task = Task.open!(caller: @caller, recipient: @recipient)
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @previous_line
  end

  test "a request is a message event for its recipient only" do
    request("please review")

    event = @recipient.event_log.sole
    assert_equal [ 1, "message" ], [ event.seq, event.kind ]
    assert_empty @caller.event_log
    assert_empty @bystander.event_log

    wire = event.to_wire(@recipient)
    assert_equal({ "id" => 1, "type" => "message", "task_id" => @task.id, "context_id" => @task.context_id },
      wire.slice("id", "type", "task_id", "context_id"))
    assert_equal({ "agent_id" => @caller.id, "handle" => "caller/caller" }, wire["from"])
    assert_equal "queue", wire["delivery"]
    assert_equal "ROLE_USER", wire.dig("message", "role")
    assert_equal [ { "text" => "please review" } ], wire.dig("message", "parts")
    assert_not wire.key?("truncated")
  end

  test "an agent never hears its own actions" do
    request("start")
    reply(state: "TASK_STATE_WORKING", parts: [ { "text" => "on it" } ])
    request("another thought")

    assert_equal %w[message message], @recipient.event_log.order(:seq).pluck(:kind)
    assert_equal %w[message state], @caller.event_log.order(:seq).pluck(:kind)
    assert(@recipient.event_log.none? { |event| event.message&.sender_agent_id == @recipient.id })
    assert(@caller.event_log.none? { |event| event.message&.sender_agent_id == @caller.id })
  end

  test "a reply is a message then a state, in the order it was written" do
    request("question")
    reply(state: "TASK_STATE_INPUT_REQUIRED", parts: [ { "text" => "which one?" } ])

    events = @caller.event_log.order(:seq).to_a
    assert_equal [ [ 1, "message" ], [ 2, "state" ] ], events.map { |event| [ event.seq, event.kind ] }
    assert_equal "TASK_STATE_INPUT_REQUIRED", events.last.to_wire(@caller)["state"]
    assert_equal({ "agent_id" => @recipient.id, "handle" => "recipient/recipient" }, events.last.to_wire(@caller)["from"])
    assert_equal "ROLE_AGENT", events.first.to_wire(@caller).dig("message", "role")
  end

  test "restating the same state is a message, not another state event" do
    request("go")
    reply(state: "TASK_STATE_WORKING")
    reply(state: "TASK_STATE_WORKING", parts: [ { "text" => "halfway" } ])

    assert_equal %w[state message], @caller.event_log.order(:seq).pluck(:kind)
  end

  test "an artifact is an event for the caller" do
    request("make it")
    reply(artifacts: [ { "name" => "result", "parts" => [ { "text" => "done" } ] } ])

    event = @caller.event_log.sole
    assert_equal "artifact", event.kind
    wire = event.to_wire(@caller)
    assert_equal "result", wire.dig("artifact", "name")
    assert_equal [ { "text" => "done" } ], wire.dig("artifact", "parts")
  end

  test "a caller's cancel is a state event for the recipient only" do
    request("never mind soon")
    @task.cancel_by_caller!(by: @caller)

    assert_equal %w[message state], @recipient.event_log.order(:seq).pluck(:kind)
    assert_equal "TASK_STATE_CANCELED", @recipient.event_log.order(:seq).last.state
    assert_empty @caller.event_log
  end

  test "sequence numbers are dense and per agent" do
    request("one")
    request("two")
    other = Task.open!(caller: @caller, recipient: @bystander)
    Message.record!(task: other, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "elsewhere" } ])

    assert_equal [ 1, 2 ], @recipient.event_log.order(:seq).pluck(:seq)
    assert_equal [ 1 ], @bystander.event_log.pluck(:seq)
    assert_equal 2, @recipient.reload.event_seq
    assert_raises(ActiveRecord::RecordNotUnique) do
      AgentEvent.create!(agent: @recipient, task: @task, kind: "state", seq: 2, state: "TASK_STATE_WORKING")
    end
  end

  test "model-free system agents and self-sends record nothing" do
    network = A2a::Network.ensure!(@organization)
    presence = Task.open!(caller: @caller, recipient: network)
    Message.record!(task: presence, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "who is there" } ])
    note = Task.open!(caller: @caller, recipient: @caller)
    Message.record!(task: note, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "to myself" } ])

    assert_equal 0, network.reload.event_seq
    assert_equal 0, @caller.reload.event_seq
    assert_equal 0, AgentEvent.count
  end

  test "release line 1 records nothing" do
    Rails.application.config.x.concourse.release_line = 1
    request("legacy")

    assert_equal 0, AgentEvent.count
    assert_equal 0, @recipient.reload.event_seq
  end

  test "events are removed with their task and the sequence keeps counting" do
    request("old")
    @task.update_columns(updated_at: 31.days.ago)
    PurgeExpiredTasksJob.perform_now

    assert_equal 0, AgentEvent.count
    assert_equal 1, @recipient.reload.event_seq

    fresh = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: fresh, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "new" } ])
    assert_equal [ 2 ], @recipient.event_log.pluck(:seq)
  end

  test "an agent that is removed takes its log with it" do
    request("soon gone")
    assert_difference -> { AgentEvent.count }, -1 do
      @recipient.destroy!
    end
  end

  test "page returns events in order and says when more remain" do
    5.times { |index| request("message #{index}") }

    first = AgentEvent.page(@recipient, after: 0, limit: 2)
    assert_equal [ 1, 2 ], first.events.pluck("id")
    assert_equal [ 2, true ], [ first.cursor, first.more ]
    second = AgentEvent.page(@recipient, after: first.cursor, limit: 2)
    assert_equal [ 3, 4 ], second.events.pluck("id")
    last = AgentEvent.page(@recipient, after: second.cursor, limit: 2)
    assert_equal [ 5 ], last.events.pluck("id")
    assert_equal [ 5, false ], [ last.cursor, last.more ]
    empty = AgentEvent.page(@recipient, after: 5)
    assert_equal [ [], 5, false ], [ empty.events, empty.cursor, empty.more ]
  end

  test "a page stops at one mebibyte but always makes progress" do
    text = "x" * 60.kilobytes
    20.times { request(text) }

    page = AgentEvent.page(@recipient, after: 0)
    assert_operator page.events.size, :<, 20
    assert_operator page.events.size, :>, 1
    assert page.more
    assert_operator JSON.generate(page.events).bytesize, :<=, AgentEvent::PAGE_BYTES
    assert_equal page.events.last["id"], page.cursor
    rest = AgentEvent.page(@recipient, after: page.cursor)
    assert_equal 20, page.events.size + rest.events.size
  end

  test "a message over 64 KiB of parts is flagged truncated and sent without them" do
    request("y" * (AgentEvent::PARTS_BYTES + 1))
    request("z" * 10.kilobytes)

    large, small = AgentEvent.page(@recipient, after: 0).events
    assert large["truncated"]
    assert_not large["message"].key?("parts")
    assert large.dig("message", "messageId")
    assert_equal "ROLE_USER", large.dig("message", "role")
    assert_not small.key?("truncated")
    assert_equal 1, small.dig("message", "parts").size
  end

  test "an event whose metadata is huge loses the metadata and is flagged truncated" do
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "small" } ],
      metadata: { "notes" => "n" * (AgentEvent::EXTRA_BYTES + 1) })

    event = AgentEvent.page(@recipient, after: 0).events.sole
    assert event["truncated"]
    assert_equal [ { "text" => "small" } ], event.dig("message", "parts")
    assert_not_includes event["message"]["metadata"].to_a.flatten, "n" * 100
    assert_equal [ "concourse.sender" ], event["message"]["metadata"].keys
    assert_operator JSON.generate(event).bytesize, :<, AgentEvent::PAGE_BYTES
  end

  test "parts are cut at exactly 64 KiB of stored bytes" do
    overhead = JSON.generate([ { "text" => "" } ]).bytesize
    request("a" * (AgentEvent::PARTS_BYTES - overhead))
    request("a" * (AgentEvent::PARTS_BYTES - overhead + 1))

    whole, cut = AgentEvent.page(@recipient, after: 0).events
    assert_not whole.key?("truncated")
    assert_equal AgentEvent::PARTS_BYTES, JSON.generate(whole.dig("message", "parts")).bytesize
    assert cut["truncated"]
    assert_not cut["message"].key?("parts")
  end

  test "a page of huge messages never loads their content into Ruby" do
    6.times { |index| request("#{index}" * 3.megabytes) }
    instantiated = Hash.new(0)
    counter = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
      instantiated[payload[:class_name]] += payload[:record_count]
    end

    page, loaded = tracking_loads { AgentEvent.page(@recipient, after: 0, limit: 4) }

    assert_equal [ 1, 2, 3, 4 ], page.events.pluck("id")
    assert page.events.all? { |event| event["truncated"] && !event["message"].key?("parts") }
    assert_equal 4, instantiated["Message"], "content for the chosen rows only"
    assert_equal 5, instantiated["AgentEvent"], "limit plus one, with no content columns"
    assert_equal 4, loaded.size
    assert_operator loaded.max, :<, 4.kilobytes, "each message arrived with its parts already emptied"
    assert_operator JSON.generate(page.events).bytesize, :<, 32.kilobytes
  ensure
    ActiveSupport::Notifications.unsubscribe(counter)
  end

  test "huge metadata and huge artifacts are emptied before they are loaded" do
    request("with notes")
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "more notes" } ],
      metadata: { "notes" => "n" * 3.megabytes })
    reply(artifacts: [ { "name" => "report", "description" => "d" * 2.megabytes, "parts" => [ { "text" => "r" * 3.megabytes } ] } ])

    heard, heard_by_caller = nil
    _, loaded = tracking_loads do
      heard = AgentEvent.page(@recipient, after: 0)
      heard_by_caller = AgentEvent.page(@caller, after: 0)
    end

    assert_equal [ false, true ], heard.events.map { |event| event.key?("truncated") }
    assert_operator loaded.max, :<, 8.kilobytes
    artifact = heard_by_caller.events.sole
    assert artifact["truncated"]
    assert_equal({ "artifactId" => artifact.dig("artifact", "artifactId") }, artifact["artifact"])
  end

  test "content is budgeted from stored sizes, so a long backlog loads about one page of it" do
    text = "p" * 60.kilobytes
    60.times { request(text) }

    page, loaded = tracking_loads { AgentEvent.page(@recipient, after: 0) }

    assert page.more
    assert_operator page.events.size, :<, 20
    assert_equal page.events.size, loaded.size, "no row was loaded and then dropped"
    assert_operator loaded.sum, :<=, AgentEvent::PAGE_BYTES + AgentEvent::EVENT_BYTES
    assert_operator JSON.generate(page.events).bytesize, :<=, AgentEvent::PAGE_BYTES
  end

  test "a backlog on the stream is read through the same bounded pages" do
    6.times { |index| request("#{index}" * 3.megabytes) }

    frames, loaded = tracking_loads do
      A2a::Exchange.with_limits(stream: 0.1, heartbeat: 5, poll: 0.01) { AgentEvent::Stream.open(@recipient, after: 0).to_enum(:each).to_a }
    end

    assert_equal 6, frames.count { |frame| frame.start_with?("id: ") }
    assert(frames.select { |frame| frame.start_with?("id: ") }.all? { |frame| frame.include?('"truncated":true') })
    assert_operator loaded.max, :<, 4.kilobytes
    assert_operator frames.sum(&:bytesize), :<, 64.kilobytes
  end

  test "an artifact over the parts limit is flagged truncated too" do
    request("big result please")
    reply(artifacts: [ { "name" => "report", "parts" => [ { "text" => "r" * (AgentEvent::PARTS_BYTES + 1) } ] } ])

    event = AgentEvent.page(@caller, after: 0).events.sole
    assert event["truncated"]
    assert_equal({ "artifactId" => event.dig("artifact", "artifactId"), "name" => "report" }, event["artifact"])
  end

  test "an agent sees only tasks it is party to while both participants are admitted" do
    request("visible")
    outsider = create_agent("outsider", organization: Organization.create!(name: "Else", slug: "else"))
    elsewhere = Task.open!(caller: outsider, recipient: create_agent("neighbour", organization: outsider.organization))
    Message.record!(task: elsewhere, role: "ROLE_USER", sender: outsider, parts: [ { "text" => "secret" } ])

    assert_equal [ @task.id ], AgentEvent.page(@recipient, after: 0).events.pluck("task_id")
    assert_empty AgentEvent.page(@bystander, after: 0).events
    assert_empty AgentEvent.page(@caller, after: 0).events

    @organization.memberships.find_by!(user: @caller.owner).remove
    assert_empty AgentEvent.page(@recipient, after: 0).events, "the sender left, so the task is out of reach"
  end

  test "acknowledging is cumulative, monotonic and idempotent" do
    3.times { request("n") }

    AgentEvent.acknowledge!(@recipient, 2)
    assert_equal 2, @recipient.reload.event_cursor
    AgentEvent.acknowledge!(@recipient, 2)
    AgentEvent.acknowledge!(@recipient, 1)
    assert_equal 2, @recipient.reload.event_cursor
    AgentEvent.acknowledge!(@recipient, 3)
    assert_equal 3, @recipient.reload.event_cursor
    assert_raises(AgentEvent::CursorInvalid) { AgentEvent.acknowledge!(@recipient, 4) }
    assert_equal 3, @recipient.reload.event_cursor
  end

  test "delivered means the recipient's cursor has reached the event" do
    2.times { request("n") }
    first, second = @recipient.event_log.order(:seq).to_a

    assert_not first.delivered?
    AgentEvent.acknowledge!(@recipient, 1)
    assert first.delivered?
    assert_not second.delivered?
  end

  test "resuming omits to the server cursor, rejects the future and reports purged ranges" do
    old = Task.open!(caller: @caller, recipient: @recipient)
    2.times { Message.record!(task: old, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "old" } ]) }
    3.times { request("kept") }
    assert_equal 0, AgentEvent.resume_point(@recipient, nil)

    AgentEvent.acknowledge!(@recipient, 3)
    assert_equal 3, AgentEvent.resume_point(@recipient.reload, nil)
    assert_equal 1, AgentEvent.resume_point(@recipient, 1)
    assert_raises(AgentEvent::CursorInvalid) { AgentEvent.resume_point(@recipient, 6) }

    old.update_columns(updated_at: 31.days.ago)
    PurgeExpiredTasksJob.perform_now
    assert_equal 3, AgentEvent.oldest(@recipient, 5)
    assert_equal 0, AgentEvent.resume_point(@recipient, 0), "a client that never read starts from what is kept"
    assert_equal 2, AgentEvent.resume_point(@recipient, 2)
    error = assert_raises(AgentEvent::CursorExpired) { AgentEvent.resume_point(@recipient, 1) }
    assert_equal 3, error.oldest
  end

  test "an agent whose events were all purged expires only cursors behind the head" do
    request("gone")
    @task.update_columns(updated_at: 31.days.ago)
    PurgeExpiredTasksJob.perform_now

    assert_equal 1, AgentEvent.resume_point(@recipient, 1)
    assert_equal 0, AgentEvent.resume_point(@recipient, 0)
    assert_equal 2, AgentEvent.oldest(@recipient, 1)
  end

  test "cursors parse strictly" do
    assert_equal 0, AgentEvent.parse_cursor("0")
    assert_equal 12, AgentEvent.parse_cursor(12)
    assert_equal 12, AgentEvent.parse_cursor("12")
    [ "", "-1", "1.5", "1e3", " 1", "0x10", "1" * 19, -1, 1.5, nil, true, [ 1 ], { "a" => 1 } ].each do |value|
      assert_raises(AgentEvent::CursorInvalid, value.inspect) { AgentEvent.parse_cursor(value) }
    end
  end

  test "a long poll waits for an event, returns it and releases its slot" do
    produced = false
    original = A2a::Waiters.method(:idle)
    task = @task
    caller = @caller
    A2a::Waiters.define_singleton_method(:idle) do |_seconds|
      unless produced
        produced = true
        Message.record!(task: task, role: "ROLE_USER", sender: caller, parts: [ { "text" => "late" } ])
      end
      original.call(0)
    end
    A2a::Waiters.reset!

    page = AgentEvent.await(@recipient, after: 0, wait: 5)
    assert_equal [ 1 ], page.events.pluck("id")
    assert A2a::Waiters.acquire(@organization.id), "the slot was released"
  ensure
    A2a::Waiters.define_singleton_method(:idle, original)
    A2a::Waiters.reset!
  end

  test "a long poll with no free slot raises, but an immediate read needs none" do
    A2a::Waiters.limit = 0
    assert_equal [], AgentEvent.await(@recipient, after: 0, wait: 0).events
    assert_raises(AgentEvent::Capacity) { AgentEvent.await(@recipient, after: 0, wait: 1) }
    request("ready now")
    assert_equal [ 1 ], AgentEvent.await(@recipient, after: 0, wait: 1).events.pluck("id")
  ensure
    A2a::Waiters.limit = nil
    A2a::Waiters.reset!
  end

  test "every read reports the oldest kept id, even for a client still at cursor 0" do
    assert_equal 1, AgentEvent.oldest_kept(@recipient)
    old = Task.open!(caller: @caller, recipient: @recipient)
    Message.record!(task: old, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "old" } ])
    request("kept")
    assert_equal 1, AgentEvent.oldest_kept(@recipient)

    old.update_columns(updated_at: 31.days.ago)
    PurgeExpiredTasksJob.perform_now

    assert_equal 2, AgentEvent.oldest_kept(@recipient)
    assert_equal 0, AgentEvent.resume_point(@recipient, nil), "a cursor of 0 is not expired, so only `oldest` shows the purge"
  end

  private

  # Runs the block and returns its value with the stored bytes of each Message
  # and Artifact it loaded.
  def tracking_loads
    Thread.current[:loaded_content] = []
    [ yield, Thread.current[:loaded_content] ]
  ensure
    Thread.current[:loaded_content] = nil
  end

  def create_agent(handle, organization: @organization)
    owner = User.create!(handle: handle, ajent_sub: "events-#{handle}", organizations: [ organization ])
    Agent.create!(owner: owner, organization: organization, handle: handle, oauth_client_id: "client-#{handle}")
  end

  def request(text)
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => text } ])
  end

  def reply(state: nil, parts: nil, artifacts: nil)
    A2a::Exchange.reply(agent: @recipient, task_id: @task.id, state: state, parts: parts, artifacts: artifacts)
  end
end
