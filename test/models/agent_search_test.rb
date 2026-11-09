require "test_helper"

class AgentSearchTest < ActiveSupport::TestCase
  setup do
    @ajay = User.create!(ajent_sub: "1", handle: "ajay", email: "ajay@example.com", organizations: [ Organization.default ])
    @riley = User.create!(ajent_sub: "2", handle: "riley", email: "riley@example.com", organizations: [ Organization.default ])
  end

  test "a blank query lists named agents by handle, up to the limit" do
    Agent.create!(owner: @riley, handle: "b", oauth_client_id: "c1")
    Agent.create!(owner: @ajay, handle: "a", oauth_client_id: "c2")
    Agent.create!(owner: @ajay, oauth_client_id: "c3")

    assert_equal [ "ajay/a" ], directory.search(nil, limit: 1).map(&:qualified_handle)
  end

  test "a skill tag outranks a mention in the description" do
    tagged = Agent.create!(
      owner: @ajay, handle: "tagged", oauth_client_id: "c1",
      skills: [ { "id" => "s", "name" => "S", "description" => "d", "tags" => [ "accounts" ] } ]
    )
    mentioned = Agent.create!(owner: @riley, handle: "mentioned", oauth_client_id: "c2", description: "Knows accounts in passing")
    Agent.create!(owner: @riley, handle: "other", oauth_client_id: "c3", description: "Invoices")

    assert_equal [ tagged, mentioned ], directory.search("Accounts")
  end

  test "a project's name finds its agents" do
    project = Organization.default.projects.create!(name: "Billing runs")
    member = Agent.create!(owner: @ajay, handle: "planner", oauth_client_id: "c1", projects: [ project ])
    Agent.create!(owner: @riley, handle: "other", oauth_client_id: "c2")

    assert_equal [ member ], directory.search("billing-runs")
  end

  test "in_project narrows the directory to a project's agents" do
    accounts = Organization.default.projects.create!(name: "Accounts")
    invoices = Organization.default.projects.create!(name: "Invoices")
    member = Agent.create!(owner: @ajay, handle: "a", oauth_client_id: "c1", projects: [ accounts, invoices ])
    Agent.create!(owner: @riley, handle: "b", oauth_client_id: "c2", projects: [ invoices ])

    assert_equal [ member ], directory.in_project(accounts).search(nil)
    assert_equal [ "accounts", "invoices" ], directory.in_project(accounts).first.directory_entry["projects"]
  end

  test "the directory is one organization's" do
    elsewhere = Organization.create!(name: "Elsewhere")
    stranger = User.create!(ajent_sub: "3", handle: "sam", organizations: [ elsewhere ])
    Agent.create!(owner: stranger, handle: "accounts", oauth_client_id: "c1")
    Agent.create!(owner: @ajay, handle: "accounts", oauth_client_id: "c2")

    assert_equal [ "ajay/accounts" ], directory.search("accounts").map(&:qualified_handle)
    assert_equal [ "sam/accounts" ], elsewhere.agents.listed.search("accounts").map(&:qualified_handle)
  end

  test "the limit stays between one and the maximum" do
    # The directory always holds concourse/conformance, so counts are relative.
    3.times { |i| Agent.create!(owner: @ajay, handle: "a#{i}", oauth_client_id: "c#{i}") }

    assert_equal 2, directory.search(nil, limit: 2).length
    assert_equal 1, directory.search(nil, limit: 0).length
    assert_operator directory.search(nil, limit: 99).length, :<=, Agent::DIRECTORY_MAX
  end

  private

  def directory
    Organization.default.agents.listed
  end
end
