require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  setup do
    @organization = Organization.default
    @ajay = User.create!(ajent_sub: "1", handle: "ajay", email: "ajay@example.com", organizations: [ @organization ])
    @agent = Agent.create!(owner: @ajay, handle: "pi", oauth_client_id: "c1")
  end

  test "the slug comes from the name, is unique within the organization, and survives a rename" do
    first = @organization.projects.create!(name: "Billing Runs")
    second = @organization.projects.create!(name: "Billing runs")
    elsewhere = Organization.create!(name: "Elsewhere").projects.create!(name: "Billing runs")

    assert_equal [ "billing-runs", "billing-runs-2", "billing-runs" ], [ first, second, elsewhere ].map(&:slug)

    first.update!(name: "Billing")
    assert_equal "billing-runs", first.reload.slug
  end

  test "an agent joins only a project in its own organization" do
    elsewhere = Organization.create!(name: "Elsewhere").projects.create!(name: "Accounts")

    participation = elsewhere.participations.build(agent: @agent)
    assert_not participation.valid?
    assert_includes participation.errors.details[:agent], { error: :another_organization }
  end

  test "deleting a project keeps its agents" do
    project = @organization.projects.create!(name: "Accounts", agents: [ @agent ])

    project.destroy!

    assert_empty @agent.reload.projects
    assert Agent.exists?(@agent.id)
  end

  test "an agent that moves to another organization leaves its projects" do
    elsewhere = Organization.create!(name: "Elsewhere")
    @ajay.organizations << elsewhere
    @organization.projects.create!(name: "Accounts", agents: [ @agent ])

    @agent.update!(organization: elsewhere)

    assert_empty @agent.reload.projects
  end
end
