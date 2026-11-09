require "test_helper"

class V3MailboxBytesTest < ActionDispatch::IntegrationTest
  setup do
    @old_release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @org = Organization.create!(name: "Mailbox bytes", slug: "mailbox-bytes")
    @caller = create_agent(@org, "bytes-caller")
    @recipient = create_agent(@org, "bytes-recipient")
    @other_org = Organization.create!(name: "Foreign bytes", slug: "foreign-bytes")
    @outsider = create_agent(@other_org, "bytes-outsider")
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @old_release
  end

  test "oversized visible mail advances the cursor without starving other mail or leaking foreign diagnostics" do
    oldest = open_mail(@caller, @recipient, "old valid", 1)
    oversized = open_mail(@caller, @recipient, "private-large-" + "x" * 1_000_000, 2)
    newest = open_mail(@caller, @recipient, "new valid", 3)
    foreign = open_mail(@outsider, @outsider, "foreign-private-" + "x" * 1_000_000, 4)
    original = oversized.reload.attributes

    assert_no_difference [ -> { TaskEvent.count }, -> { Message.count }, -> { Artifact.count }, -> { TaskDelivery.count } ] do
      body = inbox(pageSize: 2)
      assert_equal [ newest.id ], body.fetch("tasks").pluck("id")
      assert_equal [ { "taskId" => oversized.id, "code" => "INBOX_TASK_TOO_LARGE" } ], body.fetch("blockedTasks")
      assert_not_empty body.fetch("nextPageToken")
      assert_equal oversized.id, Base64.urlsafe_decode64(body.fetch("nextPageToken")).split("|").last
      assert_not_includes response.body, "private-large-"
      assert_not_includes response.body, "foreign-private-"
      assert_not_includes response.body, foreign.id
      next_body = inbox(pageSize: 2, pageToken: body.fetch("nextPageToken"))
      assert_equal [ oldest.id ], next_body.fetch("tasks").pluck("id")
      assert_empty next_body.fetch("blockedTasks")
      assert_empty next_body.fetch("nextPageToken")
    end
    assert_equal original, oversized.reload.attributes
    assert_equal "TASK_STATE_SUBMITTED", oversized.state
    get "/agents/#{@outsider.id}/tasks", headers: headers(@recipient)
    assert_response :not_found
  end

  test "byte-limited pages preserve every complete valid history without false oversized diagnostics" do
    tasks = 4.times.map { |i| open_mail(@caller, @recipient, "x" * 240_000, i + 1) }
    seen = []
    token = nil
    pages = 0
    assert_no_difference [ -> { TaskEvent.count }, -> { Message.count }, -> { TaskDelivery.count } ] do
      loop do
        body = inbox(pageSize: 50, **(token ? { pageToken: token } : {}))
        pages += 1
        assert_operator pages, :<=, 4
        assert_empty body.fetch("blockedTasks")
        body.fetch("tasks").each do |task|
          assert_equal 240_000, task.fetch("history").sole.fetch("parts").sole.fetch("text").bytesize
          seen << task.fetch("id")
        end
        token = body.fetch("nextPageToken")
        break if token.empty?
        assert_equal seen.last, Base64.urlsafe_decode64(token).split("|").last
      end
    end
    assert_operator pages, :>, 1
    assert_equal tasks.reverse.map(&:id), seen
    assert_equal seen.uniq, seen
  end

  test "the actual Rails JSON encoding including HTML escaping remains within the response byte budget" do
    tasks = 4.times.map { |i| open_mail(@caller, @recipient, "<" * 60_000, i + 1) }
    seen = []
    token = nil
    pages = 0
    loop do
      body = inbox(pageSize: 50, **(token ? { pageToken: token } : {}))
      pages += 1
      assert_operator pages, :<=, 4
      assert_empty body.fetch("blockedTasks")
      body.fetch("tasks").each do |task|
        assert_equal "<" * 60_000, task.fetch("history").sole.fetch("parts").sole.fetch("text")
        seen << task.fetch("id")
      end
      token = body.fetch("nextPageToken")
      break if token.empty?
    end
    assert_operator pages, :>, 1
    assert_equal tasks.reverse.map(&:id), seen
  end

  private

  def create_agent(org, handle)
    owner = User.create!(handle: handle, ajent_sub: handle, organizations: [ org ])
    agent = Agent.create!(owner: owner, organization: org, handle: handle, oauth_client_id: "client-#{handle}")
    stub_agent_token(handle, client_id: agent.oauth_client_id, sub: owner.ajent_sub)
    agent
  end

  def open_mail(caller, recipient, text, second)
    task = nil
    travel_to Time.utc(2026, 10, 13, 4, 0, second) do
      task = Task.open!(caller: caller, recipient: recipient)
      Message.record!(task: task, role: "ROLE_USER", sender: caller, parts: [ { "text" => text } ])
    end
    task
  end

  def headers(agent)
    { "Authorization" => "Bearer #{agent.handle}", "CONTENT_TYPE" => "application/json" }
  end

  def inbox(**params)
    get "/agents/#{@recipient.id}/tasks", params: params, headers: headers(@recipient)
    assert_response :success
    assert_operator response.body.bytesize, :<=, 768 * 1024
    response.parsed_body
  end
end
