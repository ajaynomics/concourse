require "test_helper"
require_relative "../support/machine_clients"

class AgentRetirementTest < ActiveSupport::TestCase
  include MachineClients
  setup { setup_machine_client }
  teardown do
    restore_machine_settings
    A2a::Waiters.reset!
  end

  test "retirement preserves correspondence and withdraws only one agent and its machine binding" do
    parent = @owner.agents.create!(handle: "parent", organization: @organization, oauth_client_id: "parent-client")
    sibling = Agent::ClientBinding.bind!(agent: parent, client_id: "parent-machine", verified_owner_sub: @owner.ajent_sub)
    inbound = Task.open!(caller: parent, recipient: @agent)
    Message.record!(task: inbound, sender: parent, role: "ROLE_USER", parts: [ { "text" => "keep request" } ])
    Artifact.record!(task: inbound, by: @agent, parts: [ { "text" => "keep result" } ])
    outbound = Task.open!(caller: @agent, recipient: parent)
    outbound.transition_to!("TASK_STATE_COMPLETED", by: parent)
    before = history_snapshot
    identity = @agent.reload.attributes.except("admitted_at", "declined_at", "updated_at")
    others = [ parent.reload.attributes, sibling.reload.attributes, Membership.order(:id).map(&:attributes) ]

    @agent.retire

    assert_nil @agent.reload.admitted_at
    assert @agent.declined_at
    assert @binding.reload.revoked_at
    assert_not @agent.admitted?
    assert_nil @organization.agents.named(@owner.handle, @agent.handle)
    assert_equal @agent, @organization.agents.at_address(@owner.handle, @agent.handle).sole
    assert_equal before, history_snapshot
    assert_equal identity, @agent.attributes.except("admitted_at", "declined_at", "updated_at")
    assert_equal others, [ parent.reload.attributes, sibling.reload.attributes, Membership.order(:id).map(&:attributes) ]
    assert parent.admitted?
    assert_equal parent, sibling.admitted_agent!
    assert_equal [ inbound.id, outbound.id ].sort, Task.involving_owner(@owner).pluck(:id).sort
  end

  test "repetition preserves the first withdrawal and revocation timestamps" do
    @agent.retire
    first = [ @agent.reload.attributes, @binding.reload.attributes ]
    travel 1.minute do
      @agent.retire
      assert_equal first, [ @agent.reload.attributes, @binding.reload.attributes ]
    end
  end

  test "a prior decline still revokes its binding and an absent binding is not created" do
    @agent.decline
    @agent.retire
    assert @binding.reload.revoked_at
    without_binding = @owner.agents.create!(handle: "human-only", organization: @organization)
    assert_no_difference -> { Agent::ClientBinding.count } do
      without_binding.retire
    end
    assert_not without_binding.admitted?
  end

  test "binding failure rolls back admission withdrawal too" do
    before = @agent.reload.attributes
    @agent.define_singleton_method(:revoke_client_binding) { raise ActiveRecord::RecordInvalid.new(self) }
    assert_raises(ActiveRecord::RecordInvalid) { @agent.retire }
    assert_equal before, @agent.reload.attributes
    assert_nil @binding.reload.revoked_at
  end

  test "retirement before stream consumption prevents cached initial disclosure" do
    parent = @owner.agents.create!(handle: "parent", organization: @organization)
    task = Task.open!(caller: parent, recipient: @agent)
    stream = A2a::Stream.task(task, viewer: parent)
    @agent.retire
    events = []
    stream.each { |event| events << event }
    assert_empty events
    assert_equal "TASK_STATE_SUBMITTED", task.reload.state
  end

  test "retirement stops queued stream events without changing work state" do
    parent = @owner.agents.create!(handle: "parent", organization: @organization)
    task = Task.open!(caller: parent, recipient: @agent)
    stream = A2a::Stream.task(task, viewer: parent)
    task.transition_to!("TASK_STATE_WORKING", by: @agent)
    events = []
    A2a::Exchange.with_limits(poll: 0.01, stream: 0.1) do
      stream.each do |event|
        events << event
        @agent.retire
      end
    end
    assert_equal 1, events.size
    assert_equal "TASK_STATE_WORKING", task.reload.state
    assert parent.admitted?
    assert A2a::Waiters.acquire(@organization.id)
  end

  test "retiring the caller also ends its recipient's stream" do
    parent = @owner.agents.create!(handle: "parent", organization: @organization)
    task = Task.open!(caller: @agent, recipient: parent)
    stream = A2a::Stream.task(task, viewer: parent)
    @agent.retire
    events = []
    stream.each { |event| events << event }
    assert_empty events
    assert parent.admitted?
  end

  test "a waiting inbox releases its waiter after retirement without canceling work" do
    waiting = Thread.new do
      A2a::Exchange.with_limits(inbox: 10, poll: 0.05) { A2a::Exchange.next_task(@agent) }
    end
    sleep 0.05
    @agent.retire
    assert waiting.join(2), "retired inbox waiter did not end"
    assert_nil waiting.value
    assert A2a::Waiters.acquire(@organization.id)
  ensure
    waiting&.kill
  end

  private

  def history_snapshot
    [ Task, Message, Artifact, TaskEvent ].to_h { |model| [ model.name, model.order(model.primary_key).map(&:attributes) ] }
  end
end
