require "test_helper"

class A2a::MailboxIdentifierBudgetTest < ActiveSupport::TestCase
  TASK_LIMIT = 384 * 1024
  PAGE_LIMIT = 768 * 1024

  setup do
    @old_release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Identifier budget", slug: "identifier-budget")
    @caller = agent("identifier-sender")
    @recipient = agent("identifier-recipient")
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @old_release
  end

  test "two genuinely accepted large client message IDs are blocked before materialization" do
    record = accepted_mail(message_id: "a" * 210_000)
    accepted_mail(task: record, message_id: "b" * 210_000)
    assert_equal [ "a" * 210_000, "b" * 210_000 ], record.messages.order(:created_at, :message_id).pluck(:client_message_id)
    assert_preflight_blocks(record)
  end

  test "genuinely accepted long context is counted in the task and every history message" do
    context = "private-context-" + "c" * 210_000
    record = accepted_mail(context: context)
    2.times { accepted_mail(task: record, context: context) }
    assert_equal context, record.reload.context_id
    assert_equal 3, record.messages.count
    assert_preflight_blocks(record)
  end

  test "client identifier preflight measures UTF8 bytes not characters" do
    first = "界" * 70_000
    second = "語" * 70_000
    assert_operator first.length + second.length, :<, TASK_LIMIT
    assert_operator first.bytesize + second.bytesize, :>, TASK_LIMIT
    record = accepted_mail(message_id: first)
    accepted_mail(task: record, message_id: second)
    assert_preflight_blocks(record)
  end

  test "context repetition preflight measures UTF8 bytes not characters" do
    context = "界" * 70_000
    assert_operator context.length * 4, :<, TASK_LIMIT
    assert_operator context.bytesize * 4, :>, TASK_LIMIT
    record = accepted_mail(context: context)
    2.times { accepted_mail(task: record, context: context) }
    assert_preflight_blocks(record)
  end

  test "persisted native wire message identifiers are included without enabling native delivery" do
    record = accepted_mail
    record.messages.sole.update!(native_message_id: "native-private-" + "n" * TASK_LIMIT)
    assert record.inbox?
    assert_preflight_blocks(record)
  end

  test "both persisted artifact wire identifier columns are preflighted" do
    [ :artifact_id, :native_artifact_id ].each do |column|
      record = accepted_mail
      Artifact.create!(task: record, parts: [ { "text" => "result" } ], column => "artifact-private-" + "r" * TASK_LIMIT)
      assert_preflight_blocks(record)
    end
  end

  test "below budget identifiers and context retain the complete UTF8 snapshot" do
    context = "界" * 20_000
    ids = [ "語" * 20_000, "文" * 20_000 ]
    record = accepted_mail(message_id: ids.first, context: context)
    accepted_mail(task: record, message_id: ids.last, context: context, text: "continuation")
    Artifact.record!(task: record, by: @recipient, parts: [ { "data" => { "answer" => 42 } } ], metadata: { "private" => "retained" })
    # A2A v1.0 §4.1.1: a Task snapshot preserves all previous correspondence.
    expected = A2a::Serializer.task(record.reload, artifacts: :include, caller: true)
    assert_operator ActiveSupport::JSON.encode(expected).bytesize, :<, TASK_LIMIT
    page = readonly_page([ record ], token: "selected-tail")
    assert_equal [ expected ], page.fetch("tasks")
    assert_equal ids, page.fetch("tasks").sole.fetch("history").pluck("messageId")
    assert_equal [ context, context ], page.fetch("tasks").sole.fetch("history").pluck("contextId")
    assert_empty page.fetch("blockedTasks")
    assert_equal "selected-tail", page.fetch("nextPageToken")
    assert_bounded(page)
  end

  test "processed cursor passes identifier diagnosed mail and preserves deferred valid mail" do
    first = accepted_mail(text: "x" * 280_000)
    second = accepted_mail(text: "y" * 280_000)
    oversized = accepted_mail(message_id: "a" * 210_000)
    accepted_mail(task: oversized, message_id: "b" * 210_000)
    later = accepted_mail(text: "z" * 280_000)
    page = readonly_page([ first, second, oversized, later ], token: "selected-tail")
    assert_equal [ first.id, second.id ], page.fetch("tasks").pluck("id")
    assert_equal [ diagnostic(oversized) ], page.fetch("blockedTasks")
    assert_equal oversized.id, page.fetch("nextPageToken")
    remainder = readonly_page([ later ], token: "selected-tail")
    assert_equal [ later.id ], remainder.fetch("tasks").pluck("id")
    assert_empty remainder.fetch("blockedTasks")
    assert_equal "selected-tail", remainder.fetch("nextPageToken")
    assert_bounded(page)
    assert_bounded(remainder)
  end

  private

  def agent(handle)
    owner = User.create!(handle: handle, ajent_sub: handle, organizations: [ @org ])
    Agent.create!(owner: owner, organization: @org, handle: "pi", oauth_client_id: handle)
  end

  def accepted_mail(task: nil, message_id: SecureRandom.uuid, context: nil, text: "small input")
    message = { "messageId" => message_id, "role" => "ROLE_USER", "parts" => [ { "text" => text } ] }
    message["taskId"] = task.id if task
    message["contextId"] = context if context
    assert_operator ActiveSupport::JSON.encode(message).bytesize, :<, A2a::NativeTransport::REQUEST_LIMIT
    # Genuine A2A v1.0 SendMessage (§3.1.1), not an oversized direct DB insert.
    result = A2a::Exchange.send_message(caller: @caller, recipient: @recipient, message: message,
      configuration: { "returnImmediately" => true })
    assert_includes result.fetch("history").pluck("messageId"), message_id
    assert_equal context, result.fetch("contextId") if context
    assert_equal task.id, result.fetch("id") if task
    Task.visible_to(@recipient).inbox.find(result.fetch("id"))
  end

  def diagnostic(record)
    { "taskId" => record.id, "code" => "INBOX_TASK_TOO_LARGE" }
  end

  def snapshot(records)
    records.map do |record|
      [ record.reload.attributes, *[ record.messages, record.artifacts, record.events, record.relay_deliveries, record.task_deliveries ].map { |scope|
        scope.order(scope.klass.primary_key).pluck(*scope.klass.column_names)
      } ]
    end
  end

  def readonly_page(records, token: "", instantiated: nil)
    originals = snapshot(records)
    listener = ->(*args) do
      payload = args.last
      instantiated << payload[:class_name] if instantiated && payload[:record_count].positive?
    end
    page = nil
    assert_no_difference [ -> { Task.count }, -> { Message.count }, -> { Artifact.count }, -> { TaskEvent.count },
      -> { RelayDelivery.count }, -> { TaskDelivery.count }, -> { TaskDeliveryMessage.count } ] do
      # Observe only helper serialization, after genuine acceptance and snapshot reads.
      ActiveSupport::Notifications.subscribed(listener, "instantiation.active_record") do
        page = A2a::Serializer.mailbox_page(records, next_page_token: token, page_size: 100) { |record| record.id }
      end
    end
    assert_equal originals, snapshot(records)
    page
  end

  def assert_preflight_blocks(record)
    Artifact.record!(task: record, by: @recipient, parts: [ { "text" => "small result" } ])
    instantiated = []
    blocked = readonly_page([ record ], token: "selected-tail", instantiated: instantiated)
    assert_equal [ diagnostic(record) ], blocked.fetch("blockedTasks")
    assert_empty blocked.fetch("tasks")
    assert_equal "selected-tail", blocked.fetch("nextPageToken")
    assert_not_includes instantiated, "Message"
    assert_not_includes instantiated, "Artifact"
    later = accepted_mail(text: "later small mail")
    page = readonly_page([ record, later ])
    assert_equal [ later.id ], page.fetch("tasks").pluck("id")
    assert_equal [ diagnostic(record) ], page.fetch("blockedTasks")
    assert_equal "", page.fetch("nextPageToken")
    assert_equal "TASK_STATE_SUBMITTED", record.reload.state
    assert_bounded(page)
  end

  def assert_bounded(page)
    assert_operator ActiveSupport::JSON.encode(page).bytesize, :<=, PAGE_LIMIT
    page.fetch("tasks").each { |task| assert_operator ActiveSupport::JSON.encode(task).bytesize, :<=, TASK_LIMIT }
  end
end
