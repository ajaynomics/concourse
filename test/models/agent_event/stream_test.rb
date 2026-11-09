require "test_helper"

class AgentEvent::StreamTest < ActiveSupport::TestCase
  setup do
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @organization = Organization.create!(name: "Stream", slug: "event-stream")
    @caller = create_agent("caller")
    @recipient = create_agent("recipient")
    @task = Task.open!(caller: @caller, recipient: @recipient)
    A2a::Waiters.reset!
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @previous_line
    A2a::Waiters.limit = nil
    A2a::Waiters.reset!
  end

  test "frames are ready, each event with its id, keepalive comments and bye" do
    Message.record!(task: @task, role: "ROLE_USER", sender: @caller, parts: [ { "text" => "hello" } ])

    frames = A2a::Exchange.with_limits(stream: 0.2, heartbeat: 0.03, poll: 0.01) { AgentEvent::Stream.open(@recipient, after: 0).to_enum(:each).to_a }

    assert_equal "event: ready\ndata: {\"cursor\":0,\"oldest\":1}\n\n", frames.first
    assert_match(/\Aid: 1\nevent: message\ndata: \{"id":1,"type":"message",.+\}\n\n\z/m, frames.second)
    assert_includes frames, ": keepalive\n\n"
    assert_equal "event: bye\ndata: {\"reason\":\"limit\"}\n\n", frames.last
    assert_equal 1, frames.count { |frame| frame.start_with?("id: ") }
  end

  test "a stream holds one slot until it ends" do
    A2a::Waiters.limit = 4
    stream = AgentEvent::Stream.open(@recipient, after: 0)
    assert_equal 1, A2a::Waiters.send(:count)

    stream.close
    stream.close
    assert_equal 0, A2a::Waiters.send(:count)
  end

  test "no slot, no stream" do
    A2a::Waiters.limit = 0

    assert_nil AgentEvent::Stream.open(@recipient, after: 0)
  end

  test "a client that leaves ends the stream and frees the slot without an error" do
    gone = Object.new
    def gone.write(*) = raise(IOError, "closed stream")
    def gone.close = nil

    A2a::Exchange.with_limits(stream: 1, poll: 0.01) { AgentEvent::Stream.open(@recipient, after: 0).call(gone) }

    assert_equal 0, A2a::Waiters.send(:count)
  end

  test "a failing read is reported, ends the stream and frees the slot" do
    reported = []
    subscriber = Object.new
    subscriber.define_singleton_method(:report) { |error, **| reported << error }
    Rails.error.subscribe(subscriber)
    original = AgentEvent.method(:page)
    AgentEvent.define_singleton_method(:page) { |*, **| raise "database busy" }
    io = StringIO.new

    A2a::Exchange.with_limits(stream: 1, poll: 0.01) { AgentEvent::Stream.open(@recipient, after: 0).call(io) }

    assert_equal [ "database busy" ], reported.map(&:message)
    assert_equal 0, A2a::Waiters.send(:count)
    assert_not_includes io.string, "bye"
  ensure
    AgentEvent.define_singleton_method(:page, original)
    Rails.error.unsubscribe(subscriber)
  end

  private

  def create_agent(handle)
    owner = User.create!(handle: handle, ajent_sub: "stream-#{handle}", organizations: [ @organization ])
    Agent.create!(owner: owner, organization: @organization, handle: handle, oauth_client_id: "client-#{handle}")
  end
end
