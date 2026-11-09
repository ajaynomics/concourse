require "application_system_test_case"

class OwnerFlowTest < ApplicationSystemTestCase
  setup do
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @riley = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ Organization.default ])
    @codex = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a")
    @pi = Agent.create!(owner: @riley, handle: "pi", oauth_client_id: "client-b", description: "Accounts search.")
    @paused = Task.open!(recipient: @pi, caller: @codex)
    Message.record!(task: @paused, role: "ROLE_USER", sender: @codex, parts: [ { "text" => "Which pricing rules apply?" } ])
    asked = Message.record!(task: @paused, role: "ROLE_AGENT", sender: @pi, parts: [ { "text" => "Which route?" } ])
    @paused.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @pi, status_message: asked)
    @done = Task.open!(recipient: @pi, caller: @codex)
    @done.transition_to!("TASK_STATE_COMPLETED", by: @pi)
  end

  test "from the board to an answered input request" do
    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")

    assert_text "Waiting on you"
    within("#awaiting_title + *") { find("a[href='/concourse/tasks/#{@paused.id}']").click }

    assert_text "Which route?"
    fill_in "respond_text_caller", with: "Courier for May."
    click_button "Send message"

    assert_text "Task updated."
    assert_text "Courier for May."
    assert_equal "owner", @paused.messages.order(:created_at).last.metadata["concourse.via"]
  end

  test "task filters change the list and the address, and the back button walks them" do
    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")
    within("#tab_bar") { click_link "Tasks" }

    assert_selector "#tasks_board a[href='/concourse/tasks/#{@done.id}']"
    finishing_turbo_visit_to("/concourse/tasks?filter=needs_you") { within("#tasks_board nav") { click_link "Needs you" } }
    assert_selector "#tasks_board nav [aria-current=page]", text: "Needs you"
    assert_current_path "/concourse/tasks?filter=needs_you"
    assert_no_selector "#tasks_board a[href='/concourse/tasks/#{@done.id}']"
    assert_selector "#tasks_board a[href='/concourse/tasks/#{@paused.id}']"

    go_back
    assert_current_path "/concourse/tasks"
    assert_selector "#tasks_board a[href='/concourse/tasks/#{@done.id}']"
  end

  test "a thread opens and shuts, and a live refresh leaves it as the person left it" do
    ask = Task.open!(recipient: @pi, caller: @codex, context_id: "denver")
    Message.record!(task: ask, role: "ROLE_USER", sender: @codex, parts: [ { "text" => "Reship the Denver order" } ])
    answer = Task.open!(recipient: @codex, caller: @pi, context_id: "denver")
    answer.transition_to!("TASK_STATE_WORKING", by: @codex)

    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")
    visit my_tasks_path(Organization.default)

    assert_no_selector "details[open]"
    find("details summary", text: "Reship the Denver order").click
    assert_selector "details[open] .thread-tree a[href='/concourse/tasks/#{answer.id}']"

    answer.transition_to!("TASK_STATE_COMPLETED", by: @codex)
    page.execute_script("Turbo.session.refresh(document.baseURI)")

    assert_selector "details[open] .thread-tree .state[data-state=TASK_STATE_COMPLETED]"
  end

  test "the directory filters as you type" do
    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")
    within("#tab_bar") { click_link "Agents" }

    assert_text "riley/pi"
    find("input[type=search]").fill_in with: "accounts"
    assert_text "riley/pi"
    assert_no_text "ajay/codex"
  end

  test "the recipient's owner answers as their agent and completes the task" do
    asked = Task.open!(recipient: @pi, caller: @codex)
    Message.record!(task: asked, role: "ROLE_USER", sender: @codex, parts: [ { "text" => "Cheapest courier for the May order?" } ])
    sign_in_as(subject: "7", email: "riley@example.com", name: "Riley")

    visit "/concourse/tasks/#{asked.id}"
    fill_in "respond_text_recipient", with: "CA 848 on May 12."
    select "Change to Completed", from: "respond_state"
    click_button "Send update"

    assert_text "Task updated."
    assert_text "CA 848 on May 12."
    assert_text "riley/pi completed it."
    assert_equal "TASK_STATE_COMPLETED", asked.reload.state
    assert_equal "owner", asked.status_message.metadata["concourse.via"]
  end

  test "the caller's owner cancels a task after confirming" do
    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")
    visit "/concourse/tasks/#{@paused.id}"

    accept_confirm("Cancel this task? Neither agent can restart it.") { click_button "Cancel this task" }

    # The dismissing toast can expire before a busy browser observes it.
    assert_text "Canceled."
    assert_text "ajay/codex canceled it."
    assert_equal "TASK_STATE_CANCELED", @paused.reload.state
    assert_no_selector "#respond form"
  end

  test "an owner edits their agent's card, and only their own" do
    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")
    visit "/concourse/agents/riley/pi"
    assert_no_link "Edit card"

    visit "/concourse/agents/ajay/codex"
    click_link "Edit card"
    fill_in "Display name (optional)", with: "Codex"
    fill_in "Description (optional)", with: "Reviews pull requests."
    click_button "Save card"

    assert_text "Card saved."
    assert_text "Reviews pull requests."
    assert_equal [ "Codex", "Reviews pull requests.", "codex" ], @codex.reload.values_at(:name, :description, :handle)
  end
end
