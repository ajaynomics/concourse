require "test_helper"

class TaskStatsTest < ActionDispatch::IntegrationTest
  setup do
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    travel_to Time.utc(2026, 11, 21, 12)
    @organization = Organization.create!(name: "Stats test")
    @owner = user("11", "owner-stats", @organization, role: "owner")
    @member = user("12", "member-stats", @organization)
    @other_member = user("13", "other-stats", @organization)
    @mine = agent(@owner, @organization, "mine")
    @peer = agent(@member, @organization, "peer")
    @outside_scope = agent(@other_member, @organization, "outside-scope")
  end

  teardown { Rails.application.config.x.concourse.release_line = @previous_line }

  test "counts message dates and historical state, with observed first-reply percentiles and missing replies" do
    travel_to Time.utc(2026, 11, 19, 23, 59)
    first = Task.open!(caller: @mine, recipient: @peer)
    record_message(first, @mine, "ROLE_USER")
    travel 2.minutes
    first.transition_to!("TASK_STATE_WORKING", by: @peer)
    second = Task.open!(caller: @peer, recipient: @mine)
    missing = Task.open!(caller: @mine, recipient: @peer)
    travel 1.minute
    record_message(first, @peer, "ROLE_AGENT")
    travel 5.minutes
    record_message(second, @mine, "ROLE_AGENT")
    first.transition_to!("TASK_STATE_COMPLETED", by: @peer)
    hidden = Task.open!(caller: @peer, recipient: @outside_scope)
    record_message(hidden, @outside_scope, "ROLE_AGENT", text: "hidden-sentinel")
    held = @organization.tasks.create!(caller_agent: @peer, recipient_agent: @mine, execution_route: "held", status_at: Time.current)
    Message.create!(task: held, sender_agent: @peer, role: "ROLE_USER", parts: [ { "text" => "held-sentinel" } ])
    travel_to Time.utc(2026, 11, 21, 12)
    record_message(missing, @peer, "ROLE_AGENT", text: "late-sentinel")
    sign_in(@owner)

    sql = []
    subscriber = ->(*args) { sql << args.last.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get stats_path, params: { from: "2026-11-19", through: "2026-11-20" }
    end
    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_select "body[data-controller~=analytics], body[data-controller~=ahoy], script[data-site-id], turbo-cable-stream-source", count: 0
    assert_select "h1", text: "Tasks involving your agents"
    assert_equal [
      [ "2026-11-19", "owner-stats/mine", "Submitted", "1" ],
      [ "2026-11-20", "member-stats/peer", "Unknown", "1" ],
      [ "2026-11-20", "member-stats/peer", "Working", "1" ],
      [ "2026-11-20", "owner-stats/mine", "Submitted", "1" ]
    ], css_select("#message-counts tbody tr").map { |row| row.css("td").map { |cell| cell.text.strip } }
    assert_select "#first-reply-measured", text: "2"
    assert_select "#first-reply-missing", text: "1"
    assert_select "#first-reply-median", text: "270.000 s"
    assert_select "#first-reply-p95", text: "360.000 s"
    [ first.id, second.id, missing.id, held.id, hidden.id, "message-sentinel", "hidden-sentinel", "held-sentinel", "late-sentinel", "other-stats/outside-scope" ].each do |value|
      assert_not_includes response.body, value
    end
    assert_empty sql.grep(/\A\s*(?:INSERT|UPDATE|DELETE|REPLACE)\b/i)
  end

  test "counts distinct entries into input required and only text attached to completion" do
    travel_to Time.utc(2026, 11, 20, 9)
    five = Task.open!(caller: @mine, recipient: @peer)
    four = Task.open!(caller: @mine, recipient: @peer)
    [ [ five, 5 ], [ four, 4 ] ].each do |task, times|
      times.times do
        travel 1.minute
        task.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @peer, status_message: record_message(task, @peer, "ROLE_AGENT"))
        travel 1.minute
        task.restate!(by: @peer, status_message: record_message(task, @peer, "ROLE_AGENT"))
        travel 1.minute
        task.transition_to!("TASK_STATE_WORKING", by: @peer)
      end
    end
    five.transition_to!("TASK_STATE_COMPLETED", by: @peer)
    travel 1.minute
    four.transition_to!("TASK_STATE_COMPLETED", by: @peer, status_message: record_message(four, @peer, "ROLE_AGENT"))
    with_artifact = Task.open!(caller: @mine, recipient: @peer)
    Artifact.record!(task: with_artifact, by: @peer, parts: [ { "text" => "artifact-sentinel" } ])
    with_artifact.transition_to!("TASK_STATE_COMPLETED", by: @peer)
    travel 1.minute
    sign_in(@owner)

    get stats_path, params: { from: "2026-11-20", through: "2026-11-20" }
    assert_response :success
    assert_select "#repeated-input", text: "1"
    assert_select "#completed", text: "3"
    assert_select "#completed-without-text", text: "1"
    assert_not_includes response.body, "artifact-sentinel"
  end

  test "refuses members and another organization's owner" do
    elsewhere = Organization.create!(name: "Elsewhere stats")
    elsewhere.memberships.create!(user: @member, role: "owner")
    sign_in(@member)
    get stats_path, params: { from: "2026-11-20", through: "2026-11-20" }
    assert_response :not_found
    delete sign_out_path
    sign_in(@owner)
    get stats_path(elsewhere), params: { from: "2026-11-20", through: "2026-11-20" }
    assert_response :not_found
    get mail_health_path(@organization)
    assert_select "a[href='#{stats_path}']", text: "Tasks involving your agents"
    @organization.memberships.find_by!(user: @member).update!(role: "owner")
    @organization.memberships.find_by!(user: @owner).update!(role: "member")
    get stats_path, params: { from: "2026-11-20", through: "2026-11-20" }
    assert_response :not_found
  end

  test "requires an explicit bounded UTC range before querying" do
    sign_in(@owner)
    get stats_path
    assert_response :success
    assert_select "#message-counts", count: 0
    [ { from: "2026-11-20" }, { from: "2026-10-01", through: "2026-11-20" },
      { from: "2026-11-21", through: "2026-11-22" }, { from: [ "2026-11-20" ], through: "2026-11-20" },
      { from: "2026-11-20", through: "2026-11-19" } ].each do |range|
      get stats_path, params: range
      assert_response :unprocessable_content
      assert_select "#message-counts", count: 0
    end
  end

  private

  def stats_path(organization = @organization)
    "/#{organization.slug}/stats"
  end

  def user(subject, handle, organization, role: "member")
    User.create!(ajent_sub: subject, handle: handle, email: "#{handle}@example.com").tap do |person|
      organization.memberships.create!(user: person, role: role)
    end
  end

  def agent(person, organization, handle)
    Agent.create!(owner: person, organization: organization, handle: handle, oauth_client_id: "client-#{handle}")
  end

  def sign_in(person)
    sign_in_via_ajent(subject: person.ajent_sub, email: person.email, name: person.handle)
  end

  def record_message(task, sender, role, text: "message-sentinel")
    Message.record!(task: task, role: role, sender: sender, parts: [ { "text" => text } ])
  end
end
