require "test_helper"

class Agent::OrganizationSelectionTest < ActiveSupport::TestCase
  setup do
    @settings = Rails.application.config.x.concourse
    @old_release = @settings.release_line
    @settings.release_line = 3
    @first = Organization.create!(name: "First Lab", slug: "first-lab")
    @second = Organization.create!(name: "Second Lab", slug: "second-lab")
    @outsider = Organization.create!(name: "Private Lab", slug: "private-lab")
    @owner = User.create!(ajent_sub: "selection-owner", handle: "selection-owner", organizations: [ @first, @second ])
  end

  teardown { @settings.release_line = @old_release }

  test "direct new records refuse ambiguity with a meaningful validation error" do
    candidate = @owner.agents.build
    assert_no_difference -> { Agent.count } do
      assert_not candidate.save
    end
    assert_includes candidate.errors[:organization], "must be selected when the owner belongs to multiple organizations"
    assert_nil candidate.organization
    assert candidate.update(organization: @second)
    assert_equal @second, candidate.organization
  end

  test "direct records use only the sole fresh membership and reject no membership" do
    @owner.organizations.load
    @owner.memberships.where(organization: @first).delete_all
    assert_equal @second, @owner.agents.create!.organization
    @owner.memberships.delete_all
    assert_no_difference -> { Agent.count } do
      assert_raises(ActiveRecord::RecordInvalid) { @owner.agents.create! }
    end
  end

  test "direct explicit organizations require fresh membership even with loaded associations and query cache" do
    @owner.organizations.load
    Agent.cache do
      assert @owner.memberships.exists?(organization: @second)
      Membership.connection.raw_connection.execute("DELETE FROM memberships WHERE user_id = ? AND organization_id = ?", [ @owner.id, @second.id ])
      candidate = @owner.agents.build(organization: @second)
      assert_not candidate.save
      assert_includes candidate.errors.details[:organization], { error: :not_a_member }
    end
  end

  test "new human clients must select from current memberships with no record on ambiguity" do
    assert_no_difference -> { Agent.count } do
      error = assert_raises(Agent::OrganizationSelectionRequired) { enroll }
      assert_equal "organization_required", error.data[:error]
      assert_equal choices, error.data[:organizations]
    end
    assert_equal @second, enroll(organization_slug: @second.slug).organization
    assert_equal 1, @owner.agents.where(oauth_client_id: "new-client").count
  end

  test "blank malformed unknown and nonmember selections are indistinguishable and create nothing" do
    [ "", " ", "First-Lab", "first-lab,second-lab", "../first-lab", "unknown", @outsider.slug ].each do |slug|
      assert_no_difference -> { Agent.count } do
        error = assert_raises(Agent::OrganizationSelectionRequired) { enroll(organization_slug: slug) }
        assert_equal "organization_invalid", error.data[:error]
        assert_equal choices, error.data[:organizations]
        assert_not_includes error.data[:organizations].map { |choice| choice[:slug] }, @outsider.slug
      end
    end
  end

  test "selection bypasses cached removed membership and zero membership remains unadmitted" do
    @owner.organizations.load
    Agent.cache do
      assert_equal @second, enroll(organization_slug: @second.slug).organization
      Membership.connection.raw_connection.execute("DELETE FROM memberships WHERE user_id = ? AND organization_id = ?", [ @owner.id, @second.id ])
      assert_no_difference -> { Agent.count } do
        error = assert_raises(Agent::OrganizationSelectionRequired) { enroll(client_id: "another-client", organization_slug: @second.slug) }
        assert_equal "organization_invalid", error.data[:error]
        assert_equal [ { slug: @first.slug, name: @first.name } ], error.data[:organizations]
      end
    end
    @owner.memberships.delete_all
    assert_no_difference -> { Agent.count } do
      assert_raises(Agent::Unadmitted) { enroll(client_id: "unadmitted-client", organization_slug: @first.slug) }
    end
  end

  test "an existing client keeps its organization and rejects retargeting without a write" do
    agent = enroll(organization_slug: @second.slug)
    assert_equal agent, enroll
    agent.reload.update!(last_seen_at: 1.day.ago)
    original = agent.reload.attributes
    error = assert_raises(Agent::OrganizationSelectionRequired) { enroll(organization_slug: @first.slug) }
    assert_equal "organization_conflict", error.data[:error]
    assert_equal original, agent.reload.attributes
    assert_equal agent, enroll(organization_slug: @second.slug)
    assert_equal @second, agent.reload.organization
  end

  test "established records stay valid without implicit organization changes" do
    agent = @owner.agents.create!(organization: @first)
    @owner.memberships.where(organization: @first).delete_all
    assert agent.update(name: "Preserved agent")
    assert_equal @first, agent.reload.organization
    assert_raises(ActiveRecord::RecordInvalid) { agent.update!(organization: @outsider) }
  end

  test "single membership clients remain compatible without a header" do
    @owner.memberships.where(organization: @first).delete_all
    assert_equal @second, enroll.organization
  end

  test "legacy keeps oldest membership allocation and ignores selections" do
    @settings.release_line = 1
    oldest = @owner.first_organization
    assert_equal oldest, @owner.agents.create!.organization
    assert_equal oldest, enroll(organization_slug: @outsider.slug).organization
    assert_equal oldest, enroll(organization_slug: @second.slug).organization
  end

  private

  def enroll(client_id: "new-client", **options)
    Agent.for_client!(owner: @owner, client_id: client_id, **options)
  end

  def choices
    [ @first, @second ].map { |organization| { slug: organization.slug, name: organization.name } }
  end
end
