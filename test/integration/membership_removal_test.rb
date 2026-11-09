require "test_helper"

# Removing someone from an organization takes them, and their agents, out of
# it: not just their next page, but sign-in, the directory, calls, alerts,
# and anything they were already waiting on.
class MembershipRemovalTest < ActionDispatch::IntegrationTest
  setup do
    @acme = Organization.create!(name: "Acme", email_domains: "acme.test")
    @boss = User.create!(ajent_sub: "1", handle: "boss", email: "boss@acme.test", email_verified: true)
    @acme.memberships.create!(user: @boss, role: "owner")
    @mal = User.create!(ajent_sub: "2", handle: "mal", email: "mal@acme.test", email_verified: true, organizations: [ @acme ])
    @helper = Agent.create!(owner: @boss, organization: @acme, handle: "helper", oauth_client_id: "client-boss")
    @spy = Agent.create!(owner: @mal, organization: @acme, handle: "spy", oauth_client_id: "client-mal")
  end

  test "a removed member does not come back by signing in, until an owner lets them back in" do
    sign_in_via_ajent(subject: "1", email: "boss@acme.test", name: "Boss")
    delete membership_path(@acme, @acme.memberships.find_by!(user: @mal))
    delete sign_out_path

    sign_in_via_ajent(subject: "2", email: "mal@acme.test", name: "Mal")
    get organization_root_path(@acme)
    assert_response :not_found
    assert_not @mal.organizations.reload.include?(@acme)
    delete sign_out_path

    sign_in_via_ajent(subject: "1", email: "boss@acme.test", name: "Boss")
    get edit_organization_path(@acme)
    assert_select "button[aria-label='Let #{@mal.reload} back in']"
    delete removal_path(@acme, @acme.removals.find_by!(user: @mal))
    assert_redirected_to edit_organization_path(@acme)
    delete sign_out_path

    sign_in_via_ajent(subject: "2", email: "mal@acme.test", name: "Mal")
    get organization_root_path(@acme)
    assert_response :success
  end

  test "a removed member's agent leaves the directory and cannot be called" do
    @acme.memberships.find_by!(user: @mal).remove
    with_memory_cache { stub_agent_token("token-boss", client_id: "client-boss", sub: "1", organization: @acme) }

    assert_not_includes A2a::Exchange.find_agents(@acme).map(&:qualified_handle), "mal/spy"
    assert_nil @acme.agents.named("mal", "spy")
    body = rpc(owner: "mal", agent: "spy", method: "SendMessage", token: "token-boss", organization: @acme,
      params: { message: { messageId: "m1", role: "ROLE_USER", parts: [ { text: "hi" } ] } })
    assert body["error"], body.inspect
    get "/a2a/acme/mal/spy/.well-known/agent-card.json"
    assert_response :not_found
  end

  test "a removed member gets no alerts about the organization's tasks" do
    key = WebPush.generate_key
    previous = Rails.application.config.x.vapid
    Rails.application.config.x.vapid = { subject: "mailto:test@example.com", public_key: key.public_key, private_key: key.private_key }
    @mal.push_subscriptions.create!(endpoint: "https://fcm.googleapis.com/fcm/send/mal", p256dh_key: "p", auth_key: "a")
    task = Task.open!(recipient: @spy, caller: @helper)
    @acme.memberships.find_by!(user: @mal).remove

    sent = []
    original = WebPush.method(:payload_send)
    WebPush.define_singleton_method(:payload_send) { |**options| sent << options }
    OwnerAlertJob.perform_now(@acme.id, task.id, task.status_at.utc.iso8601(6))

    assert_empty sent
  ensure
    WebPush.define_singleton_method(:payload_send, original) if original
    Rails.application.config.x.vapid = previous
  end

  test "an agent already waiting stops hearing from the organization once its owner is removed" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    waiting = Thread.new do
      A2a::Exchange.with_limits(inbox: 10, poll: 0.05) { A2a::Exchange.next_task(@spy) }
    end
    sleep 0.2
    @acme.memberships.find_by!(user: @mal).remove
    Task.open!(recipient: @spy, caller: @helper)

    assert_nil waiting.value
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  test "an agent that moved on cannot reach a task it left behind by replaying a message id" do
    elsewhere = Organization.create!(name: "Elsewhere")
    elsewhere.memberships.create!(user: @boss)
    elsewhere.memberships.create!(user: @mal)
    A2a::Exchange.send_message(caller: @helper, recipient: @spy, configuration: { "returnImmediately" => true },
      message: { "messageId" => "old", "role" => "ROLE_USER", "parts" => [ { "text" => "left behind" } ] })
    Task.where(organization: @acme).find_each { |task| task.transition_to!("TASK_STATE_COMPLETED", by: @spy) }
    @helper.reload.update!(organization: elsewhere)
    @spy.reload.update!(organization: elsewhere)

    error = assert_raises(A2a::Error) do
      A2a::Exchange.send_message(caller: @helper.reload, recipient: @spy.reload, configuration: { "returnImmediately" => true },
        message: { "messageId" => "old", "role" => "ROLE_USER", "parts" => [ { "text" => "again" } ] })
    end
    assert_equal A2a::Error::CODES[:invalid_params], error.code
  end
end
