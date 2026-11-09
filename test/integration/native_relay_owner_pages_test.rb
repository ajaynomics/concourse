require "test_helper"

class NativeRelayOwnerPagesTest < ActionDispatch::IntegrationTest
  setup do
    @organization = Organization.default
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", organizations: [ @organization ])
    other = User.create!(ajent_sub: "7", handle: "other", email: "other@example.com", organizations: [ @organization ])
    @caller = Agent.create!(owner: @owner, handle: "a", oauth_client_id: "pages-a")
    @recipient = Agent.create!(owner: other, handle: "b", oauth_client_id: "pages-b")
  end

  test "held work explains uncertainty and offers no inbox response or resend form" do
    task = Task.create!(organization: @organization, caller_agent: @caller, recipient_agent: @recipient,
      execution_route: "held", state: "TASK_STATE_SUBMITTED", context_id: SecureRandom.uuid, status_at: Time.current)
    sign_in_via_ajent
    get my_task_path(@organization, task)
    assert_response :success
    assert_select "[data-relay-route=held]", text: /Delivery is unconfirmed.*No inbox copy or automatic retry/m
    assert_select "form[action='#{my_task_response_path(@organization, task)}']", count: 0
    assert_select "form[action='#{my_task_cancellation_path(@organization, task)}']", count: 0
  end

  test "recipient native owner sees executor and freshness but has no reply or state form" do
    task = Task.create!(organization: @organization, caller_agent: @recipient, recipient_agent: @caller,
      execution_route: "native", state: "TASK_STATE_WORKING", context_id: SecureRandom.uuid, status_at: Time.current)
    relay = RelayTask.create!(task: task, organization: @organization, caller_agent: @recipient, recipient_agent: @caller,
      endpoint_url: "https://native.example.com/a2a", resource: "https://native.example.com/a2a", generation: 1,
      native_task_id: "private", observed_at: 2.minutes.ago, gap: true)
    sign_in_via_ajent
    get my_task_path(@organization, task)
    assert_response :success
    assert_select "[data-relay-route=native]", text: /The native agent owns execution.*stale.*Observation gaps/m
    assert_select "form[action='#{my_task_response_path(@organization, task)}']", count: 0
    assert_not_includes response.body, relay.native_task_id + "</dd>"
  end
end
