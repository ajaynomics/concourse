require "test_helper"

class AgentTest < ActiveSupport::TestCase
  setup { @organization = Organization.default }

  test "first sight of a client creates an unnamed agent under the subject" do
    admit("42", email: "ajay@example.com")
    agent = Agent.establish_from_introspection!(
      "sub" => "42",
      "client_id" => "client-1",
      "email" => "ajay@example.com"
    )

    assert_nil agent.handle
    assert_nil agent.name
    assert agent.unnamed?
    assert_equal "ajay", agent.owner.handle
    assert_equal "42", agent.owner.ajent_sub
    assert_equal @organization, agent.organization
    assert agent.last_seen_at.present?
  end

  test "a token from someone who never signed in on the web creates nothing" do
    assert_raises(Agent::Unadmitted) do
      Agent.establish_from_introspection!("sub" => "42", "client_id" => "client-1", "username" => "ajay@example.com")
    end

    assert_not User.exists?(ajent_sub: "42"), "no account, so no handle taken"
    assert_not User.exists?(handle: "ajay")
  end

  test "a token from someone in no organization refuses the agent" do
    User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com")

    assert_raises(Agent::Unadmitted) do
      Agent.establish_from_introspection!("sub" => "42", "client_id" => "client-1", "username" => "ajay@example.com")
    end
    assert_empty User.find_by!(ajent_sub: "42").agents
  end

  test "a token never joins an organization by email domain" do
    Organization.create!(name: "Example", email_domains: "example.com")
    User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com")

    assert_raises(Agent::Unadmitted) do
      Agent.establish_from_introspection!("sub" => "42", "client_id" => "client-1", "username" => "ajay@example.com")
    end
    assert_empty User.find_by!(ajent_sub: "42").organizations
  end

  test "without an email the owner handle is derived from sub" do
    admit("42")
    agent = Agent.establish_from_introspection!("sub" => "42", "client_id" => "client-1")

    assert_equal "sub-42", agent.owner.handle
    assert_nil agent.owner.email
  end

  test "a later sight of the same client is the same agent" do
    admit("42")
    first = Agent.establish_from_introspection!("sub" => "42", "client_id" => "client-1")
    second = Agent.establish_from_introspection!("sub" => "42", "client_id" => "client-1")

    assert_equal first, second
    assert_equal 1, Agent.count
  end

  test "a shared client id is one agent per owner" do
    admit("42", email: "ajay@example.com")
    admit("7", email: "riley@example.com")
    first = Agent.establish_from_introspection!(
      "sub" => "42", "client_id" => "https://claude.ai/client.json", "username" => "ajay@example.com"
    )
    second = Agent.establish_from_introspection!(
      "sub" => "7", "client_id" => "https://claude.ai/client.json", "username" => "riley@example.com"
    )

    assert_not_equal first, second
    assert_equal first.oauth_client_id, second.oauth_client_id
    assert_equal "ajay", first.owner.handle
    assert_equal "riley", second.owner.handle
    assert_equal 2, Agent.where(oauth_client_id: "https://claude.ai/client.json").count
  end

  test "one owner still has one agent per client registration" do
    admit("42", email: "ajay@example.com")
    first = Agent.establish_from_introspection!(
      "sub" => "42", "client_id" => "https://claude.ai/client.json", "username" => "ajay@example.com"
    )
    second = Agent.establish_from_introspection!(
      "sub" => "42", "client_id" => "https://claude.ai/client.json", "username" => "ajay@example.com"
    )

    assert_equal first, second
    assert_equal 1, Agent.count
  end

  test "two unnamed agents of one owner are allowed" do
    owner = User.create!(ajent_sub: "1", handle: "ajay", email: "ajay@example.com", organizations: [ @organization ])
    Agent.create!(owner: owner, oauth_client_id: "a")
    Agent.create!(owner: owner, oauth_client_id: "b")

    assert_equal 2, owner.agents.count
  end

  test "a new agent lands in its owner's oldest membership" do
    later = Organization.create!(name: "Later")
    owner = User.create!(ajent_sub: "1", handle: "ajay", organizations: [ @organization ])
    owner.memberships.create!(organization: later)

    assert_equal @organization, Agent.create!(owner: owner, oauth_client_id: "a").organization
  end

  test "an agent can only be in an organization its owner belongs to" do
    owner = User.create!(ajent_sub: "1", handle: "ajay", organizations: [ @organization ])
    agent = Agent.new(owner: owner, organization: Organization.create!(name: "Elsewhere"), oauth_client_id: "a")

    assert_not agent.valid?
    assert agent.errors.added?(:organization, :not_a_member)
  end

  test "an agent moves to another of its owner's organizations only with no task in progress" do
    elsewhere = Organization.create!(name: "Elsewhere")
    owner = User.create!(ajent_sub: "1", handle: "ajay", organizations: [ @organization, elsewhere ])
    peer = User.create!(ajent_sub: "2", handle: "riley", organizations: [ @organization ])
    agent = Agent.create!(owner: owner, handle: "codex", oauth_client_id: "a")
    other = Agent.create!(owner: peer, handle: "pi", oauth_client_id: "b")
    task = Task.open!(recipient: other, caller: agent)

    assert_not agent.update(organization: elsewhere)
    assert agent.errors.added?(:organization, :open_tasks)

    task.transition_to!("TASK_STATE_COMPLETED", by: other)
    assert agent.reload.update(organization: elsewhere)
    # The finished task stays where it was sent, and the agent no longer sees it.
    assert_equal @organization, task.reload.organization
    assert_not Task.visible_to(agent).exists?(task.id)
  end

  test "a lookup by handle finds only the organization's agents" do
    elsewhere = Organization.create!(name: "Elsewhere")
    owner = User.create!(ajent_sub: "1", handle: "ajay", organizations: [ @organization, elsewhere ])
    agent = Agent.create!(owner: owner, organization: elsewhere, handle: "codex", oauth_client_id: "a")

    assert_equal agent, elsewhere.agents.named("ajay", "codex")
    assert_nil @organization.agents.named("ajay", "codex")
  end

  private

  def admit(sub, email: nil)
    @organization.memberships.create!(user: User.find_or_create_from_subject!(ajent_sub: sub, email: email))
  end
end
