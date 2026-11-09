require "test_helper"
require_relative "../support/machine_clients"

class AgentRetirementsTest < ActionDispatch::IntegrationTest
  include MachineClients

  setup do
    setup_machine_client
    @old_release = @machine_settings.release_line
    @machine_settings.release_line = 3
    @owner.update!(email: "boss@retirement.test", email_verified: true)
    @organization.memberships.find_by!(user: @owner).update!(role: "owner")
    @parent = @owner.agents.create!(handle: "parent", organization: @organization, oauth_client_id: "parent-profile")
  end

  teardown do
    @machine_settings.release_line = @old_release
    restore_machine_settings
  end

  test "owner confirms exact identity and can inspect an uncertain result without replay" do
    task = Task.open!(caller: @parent, recipient: @agent)
    Message.record!(task: task, sender: @parent, role: "ROLE_USER", parts: [ { "text" => "preserve this" } ])
    sign_in_owner
    before = [ @agent.reload.attributes, @binding.reload.attributes, task.reload.attributes ]
    get retirement_url
    assert_response :success
    assert_select "input[name='retirement[agent_id]'][value='#{@agent.id}']"
    assert_select "input[name='retirement[confirmation]'][required]"
    assert_equal before, [ @agent.reload.attributes, @binding.reload.attributes, task.reload.attributes ]

    [ { agent_id: @parent.id, confirmation: @agent.qualified_handle },
      { agent_id: @agent.id, confirmation: @parent.qualified_handle },
      { agent_id: nil }, { confirmation: nil }, { admitted_at: nil } ].each do |values|
      post retirement_url, params: { retirement: confirmation.fetch(:retirement).merge(values) }
      assert_response :unprocessable_content
      assert_equal before, [ @agent.reload.attributes, @binding.reload.attributes, task.reload.attributes ]
    end

    request = confirmation
    post retirement_url, params: request
    assert_redirected_to retirement_url
    assert_not @agent.reload.admitted?
    assert @binding.reload.revoked_at
    after = [ @agent.attributes, @binding.attributes, task.reload.attributes ]
    get retirement_url
    assert_response :success
    assert_select "[role=status]", text: /Access withdrawn/
    assert_select "form input[name='retirement[confirmation]']", count: 0
    assert_equal after, [ @agent.reload.attributes, @binding.reload.attributes, task.reload.attributes ]
    post retirement_url, params: request
    assert_redirected_to retirement_url
    assert_equal after, [ @agent.reload.attributes, @binding.reload.attributes, task.reload.attributes ]

    get my_task_path(@organization, task)
    assert_response :success
    assert_includes response.body, "preserve this"
    assert @parent.reload.admitted?
  end

  test "member outsider and bearer-only callers cannot use either retirement action" do
    member = User.create!(ajent_sub: "retire-member", handle: "member", email: "member@retirement.test",
      email_verified: true, organizations: [ @organization ])
    elsewhere = Organization.create!(name: "Elsewhere", slug: "elsewhere")
    outsider = User.create!(ajent_sub: "retire-outsider", handle: "outsider", email: "outsider@retirement.test",
      email_verified: true, organizations: [ elsewhere ])
    [ member, outsider ].each do |person|
      sign_in_via_ajent(subject: person.ajent_sub, email: person.email, name: person.handle)
      get retirement_url
      assert_response :not_found
      post retirement_url, params: confirmation
      assert_response :not_found
      delete sign_out_path
    end
    stub_machine
    get retirement_url, headers: { "Authorization" => "Bearer machine-token" }
    assert_redirected_to sign_in_path
    post retirement_url, params: confirmation, headers: { "Authorization" => "Bearer machine-token" }
    assert_redirected_to sign_in_path
    assert @agent.reload.admitted?
    assert_nil @binding.reload.revoked_at
  end

  test "organization scoping and locked confirmation refuse a moved target" do
    sign_in_owner
    elsewhere = Organization.create!(name: "Elsewhere", slug: "elsewhere")
    @owner.memberships.create!(organization: elsewhere)
    outside = @owner.agents.create!(handle: "outside", organization: elsewhere)
    get retirement_path(@organization, @owner.handle, outside.handle)
    assert_response :not_found
    post retirement_path(@organization, @owner.handle, outside.handle),
      params: { retirement: { agent_id: outside.id, confirmation: outside.qualified_handle } }
    assert_response :not_found
    assert outside.reload.admitted?

    # Simulate a move after the scoped lookup, before with_lock reloads the row.
    original = Agent.instance_method(:with_lock)
    target_id = @agent.id
    moved = false
    Agent.define_method(:with_lock) do |*args, &block|
      if id == target_id && !moved
        moved = true
        Agent.where(id: id).update_all(organization_id: elsewhere.id)
      end
      original.bind_call(self, *args, &block)
    end
    post retirement_url, params: confirmation
    assert_response :not_found
    assert @agent.reload.admitted_at
    assert_nil @binding.reload.revoked_at
  ensure
    Agent.define_method(:with_lock, original) if original
  end

  test "cached machine and human credentials are denied without replacement or sibling damage" do
    with_memory_cache do
      stub_machine
      stub_agent_token("human-token", client_id: @agent.oauth_client_id, sub: @owner.ajent_sub, organization: nil)
      stub_agent_token("parent-token", client_id: @parent.oauth_client_id, sub: @owner.ajent_sub, organization: nil)
      [ "machine-token", "human-token", "parent-token" ].each do |token|
        get api_identity_path, headers: { "Authorization" => "Bearer #{token}" }
        assert_response :success
      end
      sign_in_owner
      stale_request = confirmation
      post retirement_url, params: confirmation
      assert_redirected_to retirement_url
      assert_no_difference [ -> { Agent.count }, -> { Membership.count }, -> { Agent::ClientBinding.count } ] do
        [ api_identity_path, "/agents", "/api/tasks", "/api/doorbell", worker_inbox_path(@agent) ].each do |path|
          get path, headers: { "Authorization" => "Bearer machine-token" }
          assert_response :unauthorized
        end
        get api_identity_path, headers: { "Authorization" => "Bearer human-token" }
        assert_response :forbidden
        assert_equal "declined", response.parsed_body.fetch("reason")
      end
      assert_nil @organization.agents.named(@owner.handle, @agent.handle)
      assert_not_includes A2a::Exchange.find_agents(@organization).map(&:id), @agent.id
      get api_identity_path, headers: { "Authorization" => "Bearer parent-token" }
      assert_response :success
      assert_equal @parent.id, response.parsed_body.fetch("agent_id")
      get "/a2a/#{@organization.slug}/#{@agent.qualified_handle}/.well-known/agent-card.json"
      assert_response :not_found
      assert_no_difference [ -> { Task.count }, -> { Message.count } ] do
        body = rpc(owner: @owner.handle, agent: @agent.handle, method: "SendMessage", token: "parent-token", organization: @organization,
          params: { message: { messageId: "withdrawn-target", role: "ROLE_USER", parts: [ { text: "do not enroll" } ] } })
        assert body["error"], body.inspect
      end
      post pending_agent_approval_path(@organization, @agent)
      post retirement_url, params: stale_request
      assert_response :unprocessable_content
      assert @agent.reload.admitted?
      get api_identity_path, headers: { "Authorization" => "Bearer human-token" }
      assert_response :success
      assert_equal @agent.id, response.parsed_body.fetch("agent_id")
      get api_identity_path, headers: { "Authorization" => "Bearer machine-token" }
      assert_response :unauthorized
      assert_requested :post, AgentTokens::INTROSPECT, body: hash_including("token" => "machine-token"), times: 1
      assert_requested :post, AgentTokens::INTROSPECT, body: hash_including("token" => "human-token"), times: 1
    end
  end

  private

  def retirement_url
    retirement_path(@organization, @owner.handle, @agent.handle)
  end

  def confirmation
    { retirement: { agent_id: @agent.id, confirmation: @agent.qualified_handle, admitted_at: @agent.admitted_at&.iso8601(6) } }
  end

  def sign_in_owner
    sign_in_via_ajent(subject: @owner.ajent_sub, email: @owner.email, name: "Boss")
  end
end
