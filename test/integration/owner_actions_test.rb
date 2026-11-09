require "test_helper"

class OwnerActionsTest < ActionDispatch::IntegrationTest
  setup do
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @riley = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ Organization.default ])
    @codex = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a")
    @pi = Agent.create!(owner: @riley, handle: "pi", oauth_client_id: "client-b")
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
  end

  test "as the caller, the owner answers an input request as their agent" do
    task = Task.open!(recipient: @pi, caller: @codex)
    task.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @pi)

    events = nil
    capture_events("concourse.owner.responded") do |captured|
      post my_task_response_path(Organization.default, task), params: { side: "caller", text: "Use the sre branch." }
      events = captured
    end

    assert_redirected_to my_task_path(Organization.default, task)
    message = task.messages.sole
    assert_equal "ROLE_USER", message.role
    assert_equal @codex, message.sender_agent
    assert_equal [ { "text" => "Use the sre branch." } ], message.parts
    assert_equal "owner", message.metadata["concourse.via"]
    assert task.reload.actionable?, "the recipient's next_task picks the answer up"
    assert_equal 1, events.size
    assert_not_includes events.to_json, "sre branch"
  end

  test "as the recipient, the owner replies and moves the task" do
    task = Task.open!(recipient: @codex, caller: @pi)

    post my_task_response_path(Organization.default, task), params: { side: "recipient", text: "Done.", state: "TASK_STATE_COMPLETED" }

    task.reload
    assert_equal "TASK_STATE_COMPLETED", task.state
    assert_equal @codex, task.status_message.sender_agent
    assert_equal "owner", task.status_message.metadata["concourse.via"]
  end

  test "the owner cannot speak for the side they do not hold" do
    task = Task.open!(recipient: @codex, caller: @pi)

    post my_task_response_path(Organization.default, task), params: { side: "caller", text: "Pretending to be Riley." }

    assert_redirected_to my_task_path(Organization.default, task)
    assert_equal "Couldn't send. The task may have changed; this page shows where it stands.", flash[:alert]
    assert_empty task.messages
  end

  test "a task outside the owner's scope is not found for responses or cancellation" do
    stranger = Agent.create!(owner: @riley, handle: "hermes", oauth_client_id: "client-c")
    task = Task.open!(recipient: stranger, caller: @pi)

    post my_task_response_path(Organization.default, task), params: { side: "caller", text: "hi" }
    assert_response :not_found
    post my_task_cancellation_path(Organization.default, task)
    assert_response :not_found
  end

  test "the caller's owner cancels; the recipient's cannot" do
    sent = Task.open!(recipient: @pi, caller: @codex)
    received = Task.open!(recipient: @codex, caller: @pi)

    post my_task_cancellation_path(Organization.default, sent)
    assert_equal "TASK_STATE_CANCELED", sent.reload.state

    post my_task_cancellation_path(Organization.default, received)
    assert_equal "TASK_STATE_SUBMITTED", received.reload.state
    assert_equal "This task can't be canceled now.", flash[:alert]
  end

  test "a finished task offers no reply form" do
    task = Task.open!(recipient: @codex, caller: @pi)
    task.transition_to!("TASK_STATE_COMPLETED", by: @codex)

    get my_task_path(Organization.default, task)

    assert_select "#respond form", count: 0
    assert_select "#respond", text: /finished/
  end

  test "the reply form sits inside the replay block" do
    task = Task.open!(recipient: @codex, caller: @pi)

    get my_task_path(Organization.default, task)

    assert_select "#respond form textarea[name=text]"
  end

  test "the owner edits their own agent's card, and only their own" do
    patch agent_path(Organization.default, "ajay", "codex"), params: { agent: { name: "Codex FE", description: "Frontend in storefront." } }
    assert_redirected_to agent_path(Organization.default, "ajay", "codex")
    assert_equal "Codex FE", @codex.reload.name
    assert_equal "codex", @codex.handle

    get edit_agent_path(Organization.default, "riley", "pi")
    assert_response :not_found
    patch agent_path(Organization.default, "riley", "pi"), params: { agent: { name: "mine now" } }
    assert_response :not_found
    assert_nil @pi.reload.name
  end

  test "an agent page shows what waits in its inbox" do
    waiting = Task.open!(recipient: @codex, caller: @pi)

    get agent_path(Organization.default, "ajay", "codex")

    assert_select "#inbox_title", text: "Inbox"
    assert_select "a[href='#{my_task_path(Organization.default, waiting)}']"
  end

  test "the task list pages" do
    51.times { Task.open!(recipient: @pi, caller: @codex) }

    get my_tasks_path(Organization.default)
    assert_select "a[rel=next][href='#{my_tasks_path(Organization.default, page: 2)}']"

    get my_tasks_path(Organization.default, page: 2)
    assert_select "#tasks_board ol > li", count: 1
    assert_select "a[rel=prev][href='#{my_tasks_path(Organization.default)}']"
  end
end

class PushSubscriptionsTest < ActionDispatch::IntegrationTest
  setup do
    @previous = Rails.application.config.x.vapid
    key = WebPush.generate_key
    Rails.application.config.x.vapid = { subject: "mailto:test@example.com", public_key: key.public_key, private_key: key.private_key }
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
  end

  teardown { Rails.application.config.x.vapid = @previous }

  test "a browser subscribes, and sign-out removes that browser's subscription" do
    post push_subscription_path, params: { endpoint: "https://fcm.googleapis.com/fcm/send/abc", keys: { p256dh: "p", auth: "a" } }, as: :json
    assert_response :created
    assert_equal 1, @ajay.push_subscriptions.count

    delete sign_out_path
    assert_equal 0, @ajay.push_subscriptions.count
  end

  test "a browser's alerts end with its session, however it ends" do
    post push_subscription_path, params: { endpoint: "https://fcm.googleapis.com/fcm/send/abc", keys: { p256dh: "p", auth: "a" } }, as: :json
    sam = User.create!(ajent_sub: "7", handle: "sam", email: "sam@example.com", organizations: [ Organization.default ])
    sign_in_via_ajent(subject: "7", email: "sam@example.com", name: "Sam")
    assert_equal 0, @ajay.push_subscriptions.count, "the next person's sign-in ends the last one's alerts"

    post push_subscription_path, params: { endpoint: "https://fcm.googleapis.com/fcm/send/def", keys: { p256dh: "p", auth: "a" } }, as: :json
    # Each request renews the cookie; the sign-in itself lasts 12 hours.
    travel 11.hours
    get join_path
    travel 2.hours
    get join_path
    assert_equal 0, sam.push_subscriptions.count, "an expired session ends its alerts"
  ensure
    travel_back
  end

  test "a subscription to anything but a push service is refused" do
    post push_subscription_path, params: { endpoint: "https://169.254.169.254/x", keys: { p256dh: "p", auth: "a" } }, as: :json
    assert_response :unprocessable_content
  end

  test "the alert switch is offered only with VAPID keys" do
    get organization_root_path(Organization.default)
    assert_select "[data-controller=push][data-push-key-value=?]", PushSubscription.public_key

    Rails.application.config.x.vapid = {}
    get organization_root_path(Organization.default)
    assert_select "[data-controller=push][data-push-key-value='']"
  end
end
