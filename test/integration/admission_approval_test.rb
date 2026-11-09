require "test_helper"

# An organization whose owners approve members: a claimed domain asks to join,
# an invitation joins, and an agent works only after an owner approves it.
class AdmissionApprovalTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @settings = Rails.application.config.x.concourse
    @old_release = @settings.release_line
    @settings.release_line = 3
    @firm = Organization.create!(name: "Firm", slug: "firm", email_domains: "firm.test", admission: "approval")
    @boss = User.create!(ajent_sub: "1", handle: "boss", email: "boss@firm.test", email_verified: true)
    @firm.memberships.create!(user: @boss, role: "owner")
  end

  teardown do
    @settings.release_line = @old_release
  end

  test "new organizations approve members and existing ones keep admitting automatically" do
    assert_equal "automatic", Organization.create!(name: "Old", slug: "old").admission
    assert Organization.create_with_owner!(name: "New", owner: @boss).approves_members?
  end

  test "a verified email at a claimed domain asks to join, and only an owner lets it in" do
    sign_in_via_ajent(subject: "2", email: "mal@firm.test", name: "Mal")
    mal = User.find_by!(ajent_sub: "2")
    assert_not mal.organizations.include?(@firm)
    assert @firm.join_requests.exists?(user: mal)
    get organization_root_path(@firm)
    assert_response :not_found
    delete sign_out_path

    sign_in_via_ajent(subject: "1", email: "boss@firm.test", name: "Boss")
    get edit_organization_path(@firm)
    assert_select "button[aria-label='Approve #{mal}']"
    post join_request_approval_path(@firm, @firm.join_requests.find_by!(user: mal))
    assert_redirected_to edit_organization_path(@firm)
    assert mal.organizations.reload.include?(@firm)
    assert_empty @firm.join_requests
  end

  test "a declined request does not come back at the next sign-in" do
    sign_in_via_ajent(subject: "2", email: "mal@firm.test", name: "Mal")
    mal = User.find_by!(ajent_sub: "2")
    delete sign_out_path
    sign_in_via_ajent(subject: "1", email: "boss@firm.test", name: "Boss")
    delete join_request_path(@firm, @firm.join_requests.find_by!(user: mal))
    delete sign_out_path

    sign_in_via_ajent(subject: "2", email: "mal@firm.test", name: "Mal")
    assert_empty @firm.join_requests
    assert_not mal.organizations.reload.include?(@firm)
  end

  test "an invitation admits a verified email at any domain" do
    sign_in_via_ajent(subject: "1", email: "boss@firm.test", name: "Boss")
    post invitations_path(@firm), params: { invitation: { email: " Counsel@Outside.test " } }
    assert_equal [ "counsel@outside.test" ], @firm.invitations.pluck(:email)
    delete sign_out_path

    sign_in_via_ajent(subject: "3", email: "counsel@outside.test", name: "Counsel", email_verified: false)
    assert_not User.find_by!(ajent_sub: "3").organizations.include?(@firm)
    delete sign_out_path

    sign_in_via_ajent(subject: "3", email: "counsel@outside.test", name: "Counsel")
    assert User.find_by!(ajent_sub: "3").organizations.include?(@firm)
    assert_empty @firm.invitations
  end

  test "only owners approve, decline or invite" do
    member = User.create!(ajent_sub: "4", handle: "member", email: "member@firm.test", email_verified: true, organizations: [ @firm ])
    applicant = User.create!(ajent_sub: "5", handle: "applicant", email: "applicant@firm.test")
    join_request = @firm.join_requests.create!(user: applicant)
    sign_in_via_ajent(subject: "4", email: member.email, name: "Member")
    post join_request_approval_path(@firm, join_request)
    assert_response :not_found
    post invitations_path(@firm), params: { invitation: { email: "x@y.test" } }
    assert_response :not_found
    assert_not applicant.organizations.include?(@firm)
    assert_empty @firm.invitations
  end

  test "an agent names its organization, waits for an owner, and then works" do
    stub_agent_token("boss-token", client_id: "boss-client", sub: "1", organization: nil)
    headers = { "Authorization" => "Bearer boss-token" }

    assert_no_difference -> { Agent.count } do
      get api_identity_path, headers: headers
    end
    assert_response :conflict
    assert_equal "organization_required", response.parsed_body.fetch("error")

    # The first real request creates the agent and stamps last_seen_at in one
    # transaction; owners must still hear about it.
    assert_enqueued_jobs 1, only: ApprovalAlertJob do
      get api_identity_path, headers: headers.merge("Concourse-Organization" => "firm")
    end
    assert_response :forbidden
    assert_awaiting_approval
    agent = @boss.agents.find_by!(oauth_client_id: "boss-client")
    assert_no_enqueued_jobs only: ApprovalAlertJob do
      get api_identity_path, headers: headers
    end
    assert agent.pending?
    assert_not_includes @firm.agents.admitted, agent

    get api_identity_path, headers: headers
    assert_response :forbidden
    assert_awaiting_approval

    sign_in_via_ajent(subject: "1", email: "boss@firm.test", name: "Boss")
    post pending_agent_approval_path(@firm, agent)
    assert_redirected_to edit_organization_path(@firm)

    get api_identity_path, headers: headers
    assert_response :success
    assert_equal agent.id, response.parsed_body.fetch("agent_id")
  end

  test "a declined agent keeps its tasks and is refused, not queued again, until approved" do
    stub_agent_token("boss-token", client_id: "boss-client", sub: "1", organization: nil)
    headers = { "Authorization" => "Bearer boss-token", "Concourse-Organization" => "firm" }
    get api_identity_path, headers: headers
    agent = @boss.agents.find_by!(oauth_client_id: "boss-client")
    sign_in_via_ajent(subject: "1", email: "boss@firm.test", name: "Boss")
    delete pending_agent_path(@firm, agent)
    assert agent.reload.declined_at
    assert_not_includes @firm.agents.pending, agent

    get api_identity_path, headers: headers
    assert_response :forbidden
    assert_equal "declined", response.parsed_body.fetch("reason")
    assert_match "declined", response.parsed_body.fetch("message")
    assert_not_includes @firm.agents.pending, agent.reload

    get edit_organization_path(@firm)
    assert_select "#declined_agents_title"
    post pending_agent_approval_path(@firm, agent)
    get api_identity_path, headers: headers
    assert_response :success
  end

  test "an owner removed from the organization stops their approved agent at its next request" do
    mal = User.create!(ajent_sub: "2", handle: "mal", email: "mal@firm.test", email_verified: true, organizations: [ @firm ])
    stub_agent_token("mal-token", client_id: "mal-client", sub: "2", organization: nil)
    get api_identity_path, headers: { "Authorization" => "Bearer mal-token", "Concourse-Organization" => "firm" }
    mal.agents.sole.approve
    get api_identity_path, headers: { "Authorization" => "Bearer mal-token" }
    assert_response :success

    @firm.memberships.find_by!(user: mal).remove
    get api_identity_path, headers: { "Authorization" => "Bearer mal-token" }
    assert_response :forbidden
    assert_equal "not_a_member", response.parsed_body.fetch("error")
    assert_nil response.parsed_body["reason"]
  end

  test "an agent moved into an organization that approves agents waits there" do
    open = Organization.create!(name: "Open", slug: "open")
    @boss.memberships.create!(organization: open)
    agent = @boss.agents.create!(organization: open, oauth_client_id: "mover", handle: "mover")
    assert agent.admitted?
    agent.update!(organization: @firm)
    assert agent.reload.pending?
    agent.approve
    agent.update!(name: "Mover")
    assert agent.reload.admitted?
  end

  test "a join request through sign-in alerts the owners" do
    assert_enqueued_jobs 1, only: ApprovalAlertJob do
      sign_in_via_ajent(subject: "2", email: "mal@firm.test", name: "Mal")
    end
  end

  test "turning approval off admits whoever was waiting" do
    applicant = User.create!(ajent_sub: "5", handle: "applicant", email: "applicant@firm.test")
    @firm.join_requests.create!(user: applicant)
    agent = @boss.agents.create!(organization: @firm, oauth_client_id: "waiting", admitted_at: nil)
    @firm.update!(admission: "automatic")
    assert agent.reload.admitted?
    assert applicant.organizations.include?(@firm)
    assert_empty @firm.join_requests
  end

  test "turning approval on puts existing agents up for review, but not the network agent" do
    open = Organization.create!(name: "Open", slug: "open")
    owner = User.create!(ajent_sub: "7", handle: "seven", organizations: [ open ])
    agent = owner.agents.create!(organization: open, oauth_client_id: "seven-client")
    network = A2a::Network.ensure!(open)
    assert agent.admitted?

    open.update!(admission: "approval")
    assert agent.reload.pending?
    assert_not network.reload.pending?
    open.update!(name: "Still Open")
    assert agent.reload.pending?
  end

  test "agents in automatic organizations still enrol themselves" do
    open = Organization.create!(name: "Open", slug: "open")
    stub_agent_token("open-token", client_id: "open-client", sub: "6", organization: open)
    get api_identity_path, headers: { "Authorization" => "Bearer open-token" }
    assert_response :success
    assert_not User.find_by!(ajent_sub: "6").agents.sole.pending?
  end

  private

  def assert_awaiting_approval
    assert_equal "not_a_member", response.parsed_body.fetch("error")
    assert_equal "awaiting_approval", response.parsed_body.fetch("reason")
  end
end
