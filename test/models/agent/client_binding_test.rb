require "test_helper"
require_relative "../../support/machine_clients"

class Agent::ClientBindingTest < ActiveSupport::TestCase
  include MachineClients
  setup { setup_machine_client }
  teardown { restore_machine_settings }

  test "binding preserves existing user registration and resolves only the verified agent" do
    assert_equal @agent, @binding.admitted_agent!
    assert_equal @owner.id, @binding.bound_owner_id
    assert_equal @organization.id, @binding.bound_organization_id
    assert_equal "human-profile", @agent.reload.oauth_client_id
  end

  test "a bound agent awaiting approval is told so, and a declined one is rejected" do
    @organization.update!(admission: "approval")
    assert_raises(Agent::AwaitingApproval) { @binding.admitted_agent! }
    @agent.reload.decline
    assert_raises(Agent::Declined) { @binding.admitted_agent! }
    @agent.approve
    assert_equal @agent, @binding.admitted_agent!
  end

  test "missing or mismatching verified issuer owner cannot reserve a client" do
    [ nil, "", "another-owner" ].each do |subject|
      assert_no_difference -> { Agent::ClientBinding.count } do
        assert_raises(ActiveRecord::RecordInvalid) do
          Agent::ClientBinding.bind!(agent: @agent, client_id: "another-client", verified_owner_sub: subject)
        end
      end
    end
  end

  test "unnamed unadmitted and disabled agents cannot be bound" do
    candidate = @owner.agents.create!(organization: @organization)
    assert_raises(ActiveRecord::RecordInvalid) { bind(candidate) }
    candidate.update!(handle: "candidate")
    @organization.update!(machine_clients: false)
    assert_raises(ActiveRecord::RecordInvalid) { bind(candidate) }
    @organization.update!(machine_clients: true)
    @owner.memberships.delete_all
    assert_raises(ActiveRecord::RecordInvalid) { bind(candidate) }
  end

  test "only a connected binding may wait for approval, and only while its owner is a member" do
    waiting = @owner.agents.create!(handle: "waiting", organization: @organization, admitted_at: nil)
    assert_raises(ActiveRecord::RecordInvalid) { bind(waiting) }
    @owner.memberships.delete_all
    assert_raises(ActiveRecord::RecordInvalid) { connect(waiting) }
    @owner.memberships.create!(organization: @organization)
    binding = connect(waiting)
    assert binding.connected?
    assert_not @binding.connected?
    error = assert_raises(Agent::AwaitingApproval) { binding.admitted_agent! }
    assert_equal binding, error.client_binding
    waiting.approve
    assert_equal waiting, binding.admitted_agent!
    assert_raises(ActiveRecord::RecordInvalid) { binding.update!(provenance: "operator") }
  end

  test "user registration conflicts anywhere prevent machine binding and the inverse" do
    candidate = @owner.agents.create!(handle: "candidate", organization: @organization)
    assert_raises(ActiveRecord::RecordInvalid) { bind(candidate, client_id: "human-profile") }
    assert_raises(ActiveRecord::RecordInvalid) { candidate.update!(oauth_client_id: @binding.client_id) }
    assert_raises(Ajent::Introspection::Rejected) { Agent.for_client!(owner: @owner, client_id: @binding.client_id) }
  end

  test "reservation cannot be rebound changed destroyed or unrevoked" do
    assert_raises(ActiveRecord::RecordInvalid) { @binding.update!(client_id: "changed") }
    @binding.reload
    other = @owner.agents.create!(handle: "other", organization: @organization)
    assert_raises(ActiveRecord::RecordInvalid) { @binding.update!(agent: other) }
    @binding.reload
    assert_raises(ActiveRecord::RecordNotDestroyed) { @binding.destroy! }
    @binding.revoke!
    first_revocation = @binding.revoked_at
    @binding.revoke!
    assert_equal first_revocation, @binding.revoked_at
    assert_raises(ActiveRecord::RecordInvalid) { @binding.update!(revoked_at: nil) }
  end

  test "retained binding rechecks revocation from another instance" do
    held = Agent::ClientBinding.for_client(@binding.client_id)
    assert_equal @agent, held.admitted_agent!
    Agent::ClientBinding.find(held.id).revoke!
    assert_raises(Ajent::Introspection::Rejected) { held.admitted_agent! }
    assert_raises(Ajent::Introspection::Rejected) { Agent.establish_from_introspection!(@payload) }
  end

  test "retained binding does not reuse a loaded agent after physical deletion" do
    held = Agent::ClientBinding.for_client(@binding.client_id)
    assert_equal @agent, held.admitted_agent!
    @agent.delete
    assert_raises(Ajent::Introspection::Rejected) { held.admitted_agent! }
    assert_nil held.reload.agent_id
  end

  test "physical SQL agent deletion nullifies only the reference and permanently fences reuse" do
    @agent.delete
    assert_nil @binding.reload.agent_id
    assert_equal "machine-client", @binding.client_id
    assert_raises(Ajent::Introspection::Rejected) { @binding.admitted_agent! }
    replacement = @owner.agents.create!(id: @agent.id, handle: "replacement", organization: @organization)
    assert_raises(ActiveRecord::RecordInvalid) { bind(replacement, client_id: @binding.client_id) }
    assert_raises(ActiveRecord::RecordNotUnique) do
      Agent::ClientBinding.insert_all!([ { client_id: @binding.client_id, agent_id: replacement.id,
        bound_owner_id: @owner.id, bound_organization_id: @organization.id } ])
    end
    assert_nil Agent::ClientBinding.for_client(@binding.client_id).agent_id
  end

  test "physical user deletion through normal destroy preserves reservation and rejects new owner reuse" do
    @owner.destroy!
    assert_nil @binding.reload.agent_id
    new_owner = User.create!(ajent_sub: "new-owner", handle: "new-owner", organizations: [ @organization ])
    candidate = new_owner.agents.create!(handle: "candidate", organization: @organization)
    assert_raises(ActiveRecord::RecordInvalid) do
      Agent::ClientBinding.bind!(agent: candidate, client_id: @binding.client_id, verified_owner_sub: new_owner.ajent_sub)
    end
    assert_raises(Ajent::Introspection::Rejected) { Agent.establish_from_introspection!(@payload) }
  end

  test "SQL owner deletion after SQL child deletion also leaves the reservation" do
    @agent.delete
    @owner.memberships.delete_all
    @owner.delete
    assert_nil @binding.reload.agent_id
    assert_raises(Ajent::Introspection::Rejected) { @binding.admitted_agent! }
    assert Agent::ClientBinding.for_client(@binding.client_id)
  end

  test "organization moves revoke the binding even if moved back" do
    elsewhere = Organization.create!(name: "Elsewhere", machine_clients: true)
    @owner.memberships.create!(organization: elsewhere)
    @owner.reload
    @agent.update!(organization: elsewhere)
    assert @binding.reload.revoked_at
    @agent.update!(organization: @organization)
    assert_raises(Ajent::Introspection::Rejected) { @binding.reload.admitted_agent! }
  end

  test "owner moves revoke the binding even if moved back" do
    other = User.create!(ajent_sub: "other-owner", handle: "other-owner", organizations: [ @organization ])
    @agent.update!(owner: other)
    assert @binding.reload.revoked_at
    @agent.update!(owner: @owner)
    assert_raises(Ajent::Introspection::Rejected) { Agent.establish_from_introspection!(@payload) }
  end

  test "identity snapshots reject direct SQL moves bypassing callbacks" do
    other = User.create!(ajent_sub: "other-owner", handle: "other-owner", organizations: [ @organization ])
    @agent.update_columns(owner_id: other.id)
    assert_raises(Ajent::Introspection::Rejected) { Agent::ClientBinding.for_client(@binding.client_id).admitted_agent! }
  end

  test "current membership and revocation bypass query cache" do
    Agent::ClientBinding.cache do
      assert Agent::ClientBinding.for_client(@binding.client_id).admitted_agent!
      # Raw SQLite writes intentionally leave Active Record's query cache intact.
      Membership.connection.raw_connection.execute("DELETE FROM memberships WHERE user_id = ?", [ @owner.id ])
      assert_raises(Ajent::Introspection::Rejected) { Agent::ClientBinding.for_client(@binding.client_id).admitted_agent! }
    end
    @owner.memberships.create!(organization: @organization)
    Agent::ClientBinding.cache do
      assert Agent::ClientBinding.for_client(@binding.client_id).admitted_agent!
      Agent::ClientBinding.connection.raw_connection.execute(
        "UPDATE agent_client_bindings SET revoked_at = CURRENT_TIMESTAMP WHERE id = ?", [ @binding.id ])
      assert_raises(Ajent::Introspection::Rejected) { Agent::ClientBinding.for_client(@binding.client_id).admitted_agent! }
    end
  end

  private

  def bind(agent, client_id: "candidate-client")
    Agent::ClientBinding.bind!(agent: agent, client_id: client_id, verified_owner_sub: @owner.ajent_sub)
  end

  def connect(agent)
    Agent::ClientBinding.bind_connected!(agent: agent, client_id: "connected-#{agent.handle}", verified_owner_sub: @owner.ajent_sub)
  end
end
