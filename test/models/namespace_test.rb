require "test_helper"

class NamespaceTest < ActiveSupport::TestCase
  setup do
    @harbor = Organization.create!(name: "Harbor")
    @other = Organization.create!(name: "Other")
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", organizations: [ @harbor, @other ])
  end

  test "a prefix is one name across organizations and people" do
    namespace = @harbor.namespaces.create!(name: " Northwind ")
    assert_equal "northwind", namespace.name

    assert_not @other.namespaces.new(name: "northwind").valid?
    assert_not @other.namespaces.new(name: "ajay").valid?, "a person's handle is already a prefix"
    assert_not @other.namespaces.new(name: "concourse").valid?, "reserved"
    assert_not @other.namespaces.new(name: "-bad").valid?
    assert_not User.new(ajent_sub: "7", handle: "northwind").valid?
  end

  test "a new person never gets a namespace as their handle" do
    @harbor.namespaces.create!(name: "jane")
    user = User.find_or_create_from_subject!(ajent_sub: "77", email: "jane@example.com")
    assert_equal "jane-2", user.handle
  end

  test "an agent's prefix is its namespace, or its owner's handle" do
    namespace = @harbor.namespaces.create!(name: "northwind")
    jane = Agent.create!(owner: @ajay, organization: @harbor, namespace: namespace, handle: "jane")
    plain = Agent.create!(owner: @ajay, organization: @harbor, handle: "codex")

    assert_equal "northwind/jane", jane.qualified_handle
    assert_equal "ajay/codex", plain.qualified_handle
    assert_equal "#{Concourse.app_url}/a2a/harbor/northwind/jane", A2a::Card.endpoint_url(jane)
    assert_equal "northwind/jane", A2a::Card.public_for(jane)["name"]
    assert_equal jane, @harbor.agents.named("northwind", "jane")
    assert_nil @harbor.agents.named("ajay", "jane"), "a namespaced agent leaves its owner's prefix"
    assert_equal plain, @harbor.agents.named("ajay", "codex")
    assert_nil @harbor.agents.named("northwind", "codex")
    assert_nil @other.agents.named("northwind", "jane")
  end

  test "a namespace stays with its organization" do
    namespace = @harbor.namespaces.create!(name: "northwind")
    agent = Agent.new(owner: @ajay, organization: @other, namespace: namespace, handle: "jane")
    assert_not agent.valid?

    jane = Agent.create!(owner: @ajay, organization: @harbor, namespace: namespace, handle: "jane")
    jane.update!(organization: @other)
    assert_nil jane.reload.namespace, "a moved agent goes back to its owner's prefix"
  end

  test "a handle is unique under a namespace, and a namespace in use can't be released" do
    namespace = @harbor.namespaces.create!(name: "northwind")
    riley = User.create!(ajent_sub: "7", handle: "riley", organizations: [ @harbor ])
    Agent.create!(owner: @ajay, organization: @harbor, namespace: namespace, handle: "jane")
    assert_not Agent.new(owner: riley, organization: @harbor, namespace: namespace, handle: "jane").valid?
    assert Agent.new(owner: riley, organization: @harbor, handle: "jane").valid?

    assert_not namespace.destroy
    assert Namespace.exists?(namespace.id)
  end

  test "an owner may reuse a handle under another prefix, but not twice under their own" do
    namespace = @harbor.namespaces.create!(name: "dana")
    Agent.create!(owner: @ajay, organization: @other, handle: "sam")
    reused = Agent.create!(owner: @ajay, organization: @harbor, namespace: namespace, handle: "sam")
    assert_equal "dana/sam", reused.qualified_handle
    assert_equal reused, @harbor.agents.named("dana", "sam")

    assert_not Agent.new(owner: @ajay, organization: @harbor, handle: "sam").valid?, "ajay/sam is taken"
    assert_raises(ActiveRecord::RecordNotUnique) do
      Agent.new(owner: @ajay, organization: @harbor, handle: "sam").save!(validate: false)
    end

    assert_not reused.update(organization: @other), "moving back to the owner's prefix would collide"
    assert_equal namespace, reused.reload.namespace
  end
end
