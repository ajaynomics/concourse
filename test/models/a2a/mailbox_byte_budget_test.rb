require "test_helper"

class A2a::MailboxByteBudgetTest < ActiveSupport::TestCase
  TASK_LIMIT = 384 * 1024
  PAGE_LIMIT = 768 * 1024

  setup do
    @old_release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Byte budget", slug: "byte-budget")
    @caller = agent("budget-sender")
    @recipient = agent("budget-recipient")
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @old_release
  end

  test "oversized text is diagnosed before history is instantiated and later mail survives" do
    before = mail("before")
    oversized = mail("private text " * (TASK_LIMIT / 12 + 1))
    after = mail("after")
    assert_preflight_blocks(oversized, before: before, after: after)
    assert_equal TASK_LIMIT, A2a::Serializer::MAX_INBOX_TASK_BYTES
    assert_equal PAGE_LIMIT, A2a::Serializer::MAX_INBOX_PAGE_BYTES
  end

  test "oversized artifact is diagnosed before artifact or message materialization" do
    oversized = mail("small input")
    Artifact.record!(task: oversized, by: @recipient, parts: [ { "raw" => "a" * (TASK_LIMIT + 1), "mediaType" => "application/octet-stream" } ])
    assert_preflight_blocks(oversized)
  end

  test "accumulated individually small history is preflighted as one task" do
    oversized = mail("first")
    65.times { add_message(oversized, "x" * 6000) }
    assert_preflight_blocks(oversized)
  end

  test "preflight includes conservative fixed overhead for each small history record" do
    oversized = mail("x" * 3830)
    99.times { add_message(oversized, "x" * 3830) }
    stored_bytes = oversized.messages.sum(Arel.sql("LENGTH(CAST(parts AS BLOB)) + LENGTH(CAST(metadata AS BLOB)) + LENGTH(CAST(extensions AS BLOB)) + LENGTH(CAST(reference_task_ids AS BLOB))"))
    assert_operator stored_bytes, :<, TASK_LIMIT
    assert_operator stored_bytes + oversized.messages.count * 128, :>, TASK_LIMIT
    assert_preflight_blocks(oversized)
  end

  test "preflight accounts for every persisted variable content column without loading content" do
    [ :metadata, :extensions, :reference_task_ids ].each do |column|
      oversized = mail("small")
      value = column == :metadata ? { "secret" => "x" * TASK_LIMIT } : [ "x" * TASK_LIMIT ]
      oversized.messages.sole.update!(column => value)
      assert_preflight_blocks(oversized)
    end
    [ :metadata, :extensions, :name, :description ].each do |column|
      oversized = mail("small")
      result = Artifact.record!(task: oversized, by: @recipient, parts: [ { "text" => "small" } ])
      value = case column
      when :metadata then { "secret" => "x" * TASK_LIMIT }
      when :extensions then [ "x" * TASK_LIMIT ]
      else "x" * TASK_LIMIT
      end
      result.update!(column => value)
      assert_preflight_blocks(oversized)
    end
  end

  test "SQL preflight counts UTF8 bytes rather than characters" do
    oversized = mail("界" * (TASK_LIMIT / 3 + 1))
    assert_preflight_blocks(oversized)
  end

  test "actual task byte measurement catches status content repeated from history" do
    oversized = mail("input")
    output = Message.record!(task: oversized, sender: @recipient, role: "ROLE_AGENT", parts: [ { "text" => "x" * 210_000 } ])
    oversized.restate!(by: @recipient, status_message: output)
    assert_operator JSON.generate(A2a::Serializer.task(oversized.reload, artifacts: :include, caller: true)).bytesize, :>, TASK_LIMIT
    page = readonly_page([ oversized, mail("later") ])
    assert_equal [ diagnostic(oversized) ], page.fetch("blockedTasks")
    assert_equal 1, page.fetch("tasks").size
    assert_bounded(page)
  end

  test "actual byte measurement accounts for Rails JSON escaping as well as raw text" do
    oversized = mail("<" * 70_000)
    raw = A2a::Serializer.task(oversized, artifacts: :include, caller: true)
    assert_operator JSON.generate(raw).bytesize, :<, TASK_LIMIT
    assert_operator ActiveSupport::JSON.encode(raw).bytesize, :>, TASK_LIMIT
    page = readonly_page([ oversized, mail("later") ])
    assert_equal [ diagnostic(oversized) ], page.fetch("blockedTasks")
    assert_equal 1, page.fetch("tasks").size
    assert_bounded(page)
  end

  test "under limit tasks preserve full raw history artifacts caller and output metadata" do
    record = mail("original", metadata: { "nested" => { "private" => "unchanged" } },
      extensions: [ "extension:one" ], reference_task_ids: [ "reference-one" ])
    add_message(record, "continuation")
    output = Message.record!(task: record, sender: @recipient, role: "ROLE_AGENT", parts: [ { "text" => "answer" } ])
    Artifact.record!(task: record, by: @recipient, name: "result", description: "complete result",
      parts: [ { "raw" => "Ynl0ZXM=", "filename" => "result.bin", "mediaType" => "application/octet-stream" }, { "data" => { "value" => 42 } } ],
      metadata: { "private" => "retained" }, extensions: [ "extension:result" ])
    record.restate!(by: @recipient, status_message: output)
    # A2A v1.0 §4.1.1: a snapshot retains previous content, not just new output.
    expected = A2a::Serializer.task(record.reload, artifacts: :include, caller: true)
    page = readonly_page([ record ], token: "original-continuation")
    assert_equal [ expected ], page.fetch("tasks")
    assert_equal 3, page.fetch("tasks").sole.fetch("history").size
    assert_equal @caller.qualified_handle, page.dig("tasks", 0, "metadata", "concourse.caller")
    assert_equal [ output.wire_message_id ], page.dig("tasks", 0, "metadata", "concourse.output", "messageIds")
    assert_empty page.fetch("blockedTasks")
    assert_equal "original-continuation", page.fetch("nextPageToken")
    assert_equal 100, page.fetch("pageSize")
    assert_bounded(page)
  end

  test "page exhaustion stops before a valid task and resumes after the last processed row" do
    records = [ mail("x" * 280_000), mail("x" * 280_000), mail("x" * 280_000) ]
    records.each do |record|
      assert_operator JSON.generate(A2a::Serializer.task(record, artifacts: :include, caller: true)).bytesize, :<, TASK_LIMIT
    end
    first = readonly_page(records, token: "original-selected-tail")
    assert_equal records.first(2).map(&:id), first.fetch("tasks").pluck("id")
    assert_empty first.fetch("blockedTasks"), "page exhaustion is not an individual failure"
    assert_equal records[1].id, first.fetch("nextPageToken")
    remainder = records.drop(records.index { |record| record.id == first.fetch("nextPageToken") } + 1)
    second = readonly_page(remainder, token: "original-selected-tail")
    assert_equal [ records.last.id ], second.fetch("tasks").pluck("id")
    assert_equal records.map(&:id), (first.fetch("tasks") + second.fetch("tasks")).pluck("id")
    assert_equal "original-selected-tail", second.fetch("nextPageToken")
    assert_bounded(first)
    assert_bounded(second)
  end

  test "cursor advances past blocked rows without losing deferred valid mail" do
    records = [ mail("x" * 280_000), mail("x" * 280_000), mail("x" * (TASK_LIMIT + 1)), mail("x" * 280_000) ]
    first = readonly_page(records)
    assert_equal [ diagnostic(records[2]) ], first.fetch("blockedTasks")
    assert_equal records[2].id, first.fetch("nextPageToken")
    second = readonly_page(records.drop(3))
    assert_equal [ records.last.id ], second.fetch("tasks").pluck("id")
    assert_empty second.fetch("blockedTasks")
    assert_equal "", second.fetch("nextPageToken")
    assert_bounded(first)
    assert_bounded(second)
  end

  test "all blocked rows and empty selections retain the caller original continuation" do
    records = 3.times.map { mail("x" * (TASK_LIMIT + 1)) }
    page = readonly_page(records, token: "caller-tail")
    assert_empty page.fetch("tasks")
    assert_equal records.map { |record| diagnostic(record) }, page.fetch("blockedTasks")
    assert_equal "caller-tail", page.fetch("nextPageToken")
    empty = readonly_page([], token: "empty-tail")
    assert_equal({ "tasks" => [], "blockedTasks" => [], "nextPageToken" => "empty-tail", "pageSize" => 100 }, empty)
    assert_bounded(page)
  end

  private

  def agent(handle)
    owner = User.create!(handle: handle, ajent_sub: handle, email: "#{handle}@example.test", organizations: [ @org ])
    Agent.create!(owner: owner, organization: @org, handle: "pi", oauth_client_id: handle)
  end

  def mail(text, **options)
    Task.open!(caller: @caller, recipient: @recipient).tap { |record| add_message(record, text, **options) }
  end

  def add_message(record, text, **options)
    Message.record!(task: record, sender: @caller, role: "ROLE_USER", parts: [ { "text" => text } ], **options)
  end

  def diagnostic(record)
    { "taskId" => record.id, "code" => "INBOX_TASK_TOO_LARGE" }
  end

  def readonly_page(records, token: "")
    originals = records.map { |record| record.reload.attributes }
    page = nil
    assert_no_difference [ -> { Task.count }, -> { Message.count }, -> { Artifact.count }, -> { TaskEvent.count }, -> { TaskDelivery.count }, -> { TaskDeliveryMessage.count } ] do
      page = A2a::Serializer.mailbox_page(records, next_page_token: token, page_size: 100) { |record| record.id }
    end
    assert_equal originals, records.map { |record| record.reload.attributes }
    page
  end

  def assert_preflight_blocks(oversized, before: nil, after: nil)
    instantiated = []
    listener = ->(*args) do
      payload = args.last
      instantiated << payload[:class_name] if payload[:record_count].positive?
    end
    blocked = nil
    ActiveSupport::Notifications.subscribed(listener, "instantiation.active_record") do
      blocked = readonly_page([ oversized ])
    end
    assert_equal [ diagnostic(oversized) ], blocked.fetch("blockedTasks")
    assert_empty blocked.fetch("tasks")
    assert_not_includes instantiated, "Message"
    assert_not_includes instantiated, "Artifact"
    records = [ before, oversized, after ].compact
    page = readonly_page(records, token: "caller-tail")
    assert_equal [ before, after ].compact.map(&:id), page.fetch("tasks").pluck("id")
    assert_equal [ diagnostic(oversized) ], page.fetch("blockedTasks")
    assert_equal "caller-tail", page.fetch("nextPageToken")
    assert_equal "TASK_STATE_SUBMITTED", oversized.reload.state
    assert oversized.messages.exists?, "diagnostics must not consume or delete correspondence"
    assert_bounded(page)
  end

  def assert_bounded(page)
    assert_operator JSON.generate(page).bytesize, :<=, PAGE_LIMIT
    assert_operator ActiveSupport::JSON.encode(page).bytesize, :<=, PAGE_LIMIT
    page.fetch("tasks").each { |task| assert_operator JSON.generate(task).bytesize, :<=, TASK_LIMIT }
  end
end
