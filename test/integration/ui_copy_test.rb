require "test_helper"

class UiCopyTest < ActionDispatch::IntegrationTest
  setup do
    @organization = Organization.create!(name: "Example team")
    @user = User.create!(ajent_sub: "ui-copy-owner", handle: "kim", email: "kim@example.test", organizations: [ @organization ])
    @teammate = User.create!(ajent_sub: "ui-copy-peer", handle: "lee", email: "lee@example.test", organizations: [ @organization ])
    sign_in_via_ajent(subject: @user.ajent_sub, email: @user.email, name: "Kim")
  end

  test "empty directory and task list offer relevant next steps" do
    get agents_path(@organization)
    assert_response :success
    assert_select "main a[href=?]", join_path, text: I18n.t("agents.index.connect")
    assert_select "[data-filter-target=empty][role=status][aria-live=polite]"

    get my_tasks_path(@organization)
    assert_select "#tasks_board a[href=?]", agents_path(@organization), text: I18n.t("owner_tasks.index.browse_agents")
    assert_select "main p", text: I18n.t("owner_tasks.index.retention")

    get my_tasks_path(@organization, filter: "needs_you")
    assert_select "#tasks_board a[href=?]", my_tasks_path(@organization), text: I18n.t("owner_tasks.index.view_all")
  end

  test "project onboarding links back to the directory and explains membership" do
    get projects_path(@organization)
    assert_response :success
    assert_select "main a[href=?]", new_project_path(@organization)
    assert_select "main a[href=?]", agents_path(@organization), text: I18n.t("projects.index.directory")
    assert_select "main p", text: I18n.t("projects.index.empty")
  end

  test "endpoint and guide copy controls expose translated recovery and polite feedback" do
    agent = Agent.create!(owner: @user, organization: @organization, handle: "codex", oauth_client_id: "ui-copy-client")
    get agent_path(@organization, @user.handle, agent.handle)
    assert_response :success
    assert_select "[data-controller=clipboard][data-clipboard-failed-value=?]", I18n.t("agents.show.copy_failed")
    assert_select "[data-clipboard-target=feedback][role=status][aria-live=polite]"
    assert_select "[data-clipboard-target=idle]"
    assert_select "[data-clipboard-target=done]"

    get join_path
    assert_select "[data-controller=code-copy][data-code-copy-failed-value=?]", I18n.t("joins.show.copy_failed")
  end

  test "task responses explain the owner's side without offering another agent's controls" do
    own = Agent.create!(owner: @user, organization: @organization, handle: "codex", oauth_client_id: "ui-copy-client")
    peer = Agent.create!(owner: @teammate, organization: @organization, handle: "claude", oauth_client_id: "ui-copy-peer-client")
    received = Task.open!(recipient: own, caller: peer)
    get my_task_path(@organization, received)
    assert_select "#messages_title", text: /Messages/
    assert_select "#respond p", text: I18n.t("owner_tasks.respond.recipient.hint")
    assert_select "#respond textarea[aria-describedby=respond_hint_recipient]"
    assert_select "#respond select[name=state]"
    assert_select "#respond input[name=side][value=caller]", count: 0

    sent = Task.open!(recipient: peer, caller: own)
    get my_task_path(@organization, sent)
    assert_select "#respond p", text: I18n.t("owner_tasks.respond.caller.hint")
    assert_select "#respond textarea[required][aria-describedby=respond_hint_caller]"
    assert_select "#respond select[name=state]", count: 0
    assert_select "main p", text: I18n.t("owner_tasks.index.retention")
  end

  test "a state-only owner update does not claim a person wrote a message" do
    own = Agent.create!(owner: @user, organization: @organization, handle: "codex", oauth_client_id: "ui-copy-client")
    peer = Agent.create!(owner: @teammate, organization: @organization, handle: "claude", oauth_client_id: "ui-copy-peer-client")
    task = Task.open!(recipient: own, caller: peer)
    post my_task_response_path(@organization, task), params: { side: "recipient", text: "", state: "TASK_STATE_COMPLETED" }
    assert_redirected_to my_task_path(@organization, task)
    assert_equal "TASK_STATE_COMPLETED", task.reload.state
    assert_empty task.messages
    assert_equal "Task updated.", flash[:notice]
  end
end
