require "test_helper"

class MailHealthTest < ActionDispatch::IntegrationTest
  setup do
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    @organization = Organization.create!(name: "Dana", slug: "dana-health")
    @owner = User.create!(ajent_sub: "42", handle: "dana", email: "dana@example.com", name: "Dana")
    @organization.memberships.create!(user: @owner, role: "owner")
    @member = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ @organization ])
    @assistant = Agent.create!(owner: @owner, organization: @organization, handle: "sam-lee", oauth_client_id: "client-a")
    @peer = Agent.create!(owner: @member, organization: @organization, handle: "pi", oauth_client_id: "client-b")
  end

  teardown { Rails.application.config.x.concourse.release_line = @previous_line }

  test "an owner sees each agent's counts, linked from the board, and no task content" do
    stuck = Task.open!(caller: @peer, recipient: @assistant)
    Message.record!(task: stuck, role: "ROLE_USER", sender: @peer, parts: [ { "text" => "secret-sentinel" } ])
    travel 45.minutes
    waiting = Task.open!(caller: @peer, recipient: @assistant)
    Message.record!(task: waiting, role: "ROLE_USER", sender: @peer, parts: [ { "text" => "another" } ])
    travel 20.minutes

    sign_in_via_ajent(subject: "42", email: "dana@example.com", name: "Dana")
    get organization_root_path(@organization)
    assert_select "a[href='#{mail_health_path(@organization)}']", text: "Mail health"

    get mail_health_path(@organization)
    assert_response :success
    assert_equal "/dana-health/health", mail_health_path(@organization)
    assert_select "h1", text: "One agent's mail is stuck."
    assert_select "##{ActionView::RecordIdentifier.dom_id(@assistant, :mail_health)}" do
      assert_select "*", text: /Stuck over an hour/
      assert_select "dd", text: /1 over an hour\./
      assert_select "dd", text: /1 over 15 minutes, possibly waiting on a person\./
    end
    assert_select "##{ActionView::RecordIdentifier.dom_id(@peer, :mail_health)}", text: /Nothing waiting over 15 minutes/
    assert_not_includes response.body, "secret-sentinel"
    assert_not_includes response.body, stuck.id
  end

  test "a member who is not an owner, and a non-member, are refused" do
    sign_in_via_ajent(subject: "7", email: "riley@example.com", name: "Riley")
    get organization_root_path(@organization)
    assert_select "a[href='#{mail_health_path(@organization)}']", count: 0
    get mail_health_path(@organization)
    assert_response :not_found

    elsewhere = Organization.create!(name: "Elsewhere", slug: "elsewhere-health")
    User.create!(ajent_sub: "9", handle: "stranger", email: "stranger@example.com", name: "Stranger", organizations: [ elsewhere ])
    delete sign_out_path
    sign_in_via_ajent(subject: "9", email: "stranger@example.com", name: "Stranger")
    get mail_health_path(@organization)
    assert_response :not_found
  end
end
