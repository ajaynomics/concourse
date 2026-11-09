require "test_helper"

# Real writer processes against one reader on the real SQLite file. Each
# process has its own connection, so writers contend for the file lock as
# production writers do. The reader must see every event of each log exactly
# once and in order, and never see a number before every lower number.
#
# Transactions are off for this class because a forked writer cannot see an
# uncommitted setup; teardown deletes what it committed.
class AgentEventConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  WRITERS = 4
  PER_WRITER = 25
  RECIPIENTS = 2
  DEADLINE = 60

  setup do
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @tag = SecureRandom.hex(4)
    @organization = Organization.create!(name: "Race", slug: "event-race-#{@tag}")
    @users = []
    @recipients = RECIPIENTS.times.map { |index| create_agent("recipient-#{index}") }
    @writers = WRITERS.times.map { |index| create_agent("writer-#{index}") }
    @tasks = @writers.to_h { |writer| [ writer.id, @recipients.map { |recipient| Task.open!(caller: writer, recipient: recipient) } ] }
    @children = []
  end

  teardown do
    @children.each { |pid| Process.kill("KILL", pid) rescue nil } # rubocop:disable Style/RescueModifier
    @children.each { |pid| Process.wait(pid) rescue nil } # rubocop:disable Style/RescueModifier
    @users.each(&:destroy!)
    # Creating an organization also created its network agent, owned by the system user.
    # reload: the has_many cache still lists agents destroyed through their owners.
    @organization.reload.agents.each(&:destroy!)
    @organization.reload.destroy!
    Rails.application.config.x.concourse.release_line = @previous_line
  end

  test "concurrent writers never make a reader skip, repeat or reorder an event" do
    start, release = IO.pipe
    @writers.each_with_index { |writer, index| @children << fork_writer(writer, index, start, release) }
    start.close
    release.close # the writers begin together when the last copy of the write end closes

    expected = WRITERS * PER_WRITER
    cursors = @recipients.to_h { |recipient| [ recipient.id, 0 ] }
    seen = @recipients.to_h { |recipient| [ recipient.id, [] ] }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE
    reads = 0

    until cursors.values.all?(expected)
      flunk "writers did not finish: #{cursors.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      progressed = false
      @recipients.each do |recipient|
        page = AgentEvent.page(recipient, after: cursors[recipient.id], limit: 7)
        reads += 1
        ids = page.events.pluck("id")
        next if ids.empty?

        progressed = true
        # A late commit of a lower number would show up as a hole here.
        assert_equal (cursors[recipient.id] + 1..cursors[recipient.id] + ids.size).to_a, ids
        seen[recipient.id].concat(page.events)
        cursors[recipient.id] = page.cursor
      end
      sleep 0.001 unless progressed
    end
    statuses = @children.map { |pid| Process.wait2(pid).last }
    @children.clear

    assert statuses.all?(&:success?), statuses.map(&:inspect).join(", ")
    assert_operator reads, :>, RECIPIENTS, "the reader raced the writers, not only read at the end"
    @recipients.each do |recipient|
      assert_equal expected, recipient.reload.event_seq
      assert_equal (1..expected).to_a, seen[recipient.id].pluck("id")
      texts = seen[recipient.id].map { |event| event.dig("message", "parts", 0, "text") }
      assert_equal expected, texts.uniq.size
      @writers.each_index do |index|
        # Within one writer the reader sees its messages in the order it wrote them.
        own = texts.filter_map { |text| text[/\Aw#{index}-(\d+)\z/, 1]&.to_i }
        assert_equal (0...PER_WRITER).to_a, own, "writer #{index} reordered for #{recipient.handle}"
      end
    end
    assert_empty AgentEvent.where(agent_id: @writers.map(&:id)), "writers hear nothing of their own sends"
  end

  private

  def create_agent(handle)
    owner = User.create!(handle: "#{handle}-#{@tag}", ajent_sub: "race-#{handle}-#{@tag}", organizations: [ @organization ])
    @users << owner
    Agent.create!(owner: owner, organization: @organization, handle: handle, oauth_client_id: "client-#{handle}-#{@tag}")
  end

  # A writer sends PER_WRITER messages to every recipient, alternating, as its
  # own process. exit! skips Minitest's at_exit, which would rerun the suite.
  def fork_writer(writer, index, start, release)
    fork do
      status = 1
      begin
        release.close # else this copy of the write end keeps the pipe open forever
        start.read # blocks until every other copy of the write end is closed
        PER_WRITER.times do |sequence|
          @tasks.fetch(writer.id).each do |task|
            Message.record!(task: task, role: "ROLE_USER", sender: writer, parts: [ { "text" => "w#{index}-#{sequence}" } ])
          end
        end
        status = 0
      rescue Exception => error # rubocop:disable Lint/RescueException
        warn "writer #{index}: #{error.class}: #{error.message}"
      ensure
        exit!(status)
      end
    end
  end
end
