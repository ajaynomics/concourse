require "test_helper"
require_relative "../support/machine_clients"

# The event log authenticates exactly as the other /api routes: a bound machine
# client reaches its existing agent's log, and nothing else's.
class AgentEventsMachineClientTest < ActionDispatch::IntegrationTest
  include MachineClients

  setup do
    @previous_line = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
    setup_machine_client
    sender_owner = User.create!(handle: "lab-sender", ajent_sub: "lab-sender", organizations: [ @organization ])
    @sender = sender_owner.agents.create!(handle: "sender", organization: @organization, oauth_client_id: "lab-sender-client")
    @task = Task.open!(caller: @sender, recipient: @agent)
    Message.record!(task: @task, role: "ROLE_USER", sender: @sender, parts: [ { "text" => "for the machine" } ])
  end

  teardown do
    restore_machine_settings
    Rails.application.config.x.concourse.release_line = @previous_line
  end

  test "a bound machine client reads and acknowledges the log of its existing agent" do
    stub_machine
    get api_events_path, headers: bearer
    assert_response :success
    assert_equal [ @task.id ], response.parsed_body["events"].pluck("task_id")

    put api_events_cursor_path, params: { cursor: 1 }.to_json, headers: bearer.merge("CONTENT_TYPE" => "application/json")
    assert_response :no_content
    assert_equal 1, @agent.reload.event_cursor
    get api_me_path, headers: bearer
    assert_equal %w[events events.sse], response.parsed_body["capabilities"]
  end

  test "a machine client without an opted-in organization is rejected" do
    stub_machine
    @organization.update!(machine_clients: false)

    get api_events_path, headers: bearer
    assert_response :unauthorized
    put api_events_cursor_path, params: { cursor: 1 }.to_json, headers: bearer.merge("CONTENT_TYPE" => "application/json")
    assert_response :unauthorized
    assert_equal 0, @agent.reload.event_cursor
  end

  test "a machine token for the wrong audience is rejected" do
    stub_machine(@payload.merge("aud" => "#{Concourse.app_url}/mcp"))

    get api_events_path, headers: bearer
    assert_response :unauthorized
  end

  private

  def bearer(token = "machine-token")
    { "Authorization" => "Bearer #{token}" }
  end
end
