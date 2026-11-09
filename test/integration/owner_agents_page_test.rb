require "test_helper"

# The agents page is where owners manage agents: waiting ones at the top,
# and a one-click Retire on each live one. Members see neither.
class OwnerAgentsPageTest < ActionDispatch::IntegrationTest
  setup do
    @organization = Organization.create!(name: "Firm", slug: "firm", admission: "approval")
    @boss = User.create!(ajent_sub: "page-boss", handle: "boss", email: "boss@firm.test", email_verified: true)
    @member = User.create!(ajent_sub: "page-member", handle: "member", email: "member@firm.test", email_verified: true)
    @organization.memberships.create!(user: @boss, role: "owner")
    @organization.memberships.create!(user: @member)
    @live = @member.agents.create!(handle: "live", organization: @organization, oauth_client_id: "live-client", admitted_at: Time.current)
    @waiting = @member.agents.create!(handle: "waiting", organization: @organization, oauth_client_id: "waiting-client", admitted_at: nil)
  end

  test "owners see waiting agents with approve and decline, and retire on live agents" do
    sign_in(@boss)
    get agents_path(@organization)
    assert_response :success
    assert_select "#waiting_title", text: /Waiting for approval/
    assert_select "#pending_agent_#{@waiting.id} form[action=?]", pending_agent_approval_path(@organization, @waiting)
    assert_select "#pending_agent_#{@waiting.id} form[action=?] input[name=_method][value=delete]", pending_agent_path(@organization, @waiting)
    assert_select "form[action=?][data-turbo-confirm=?]", retirement_path(@organization, "member", "live"),
      "Retire member/live? It stops at once; its past tasks stay."
    assert_select "form[action=?] input[name='retirement[confirmation]'][value='member/live']", retirement_path(@organization, "member", "live")

    post pending_agent_approval_path(@organization, @waiting), headers: { "Referer" => agents_url(@organization) }
    assert_redirected_to agents_url(@organization)
    assert @waiting.reload.admitted?

    post retirement_path(@organization, "member", "live"),
      params: { retirement: { agent_id: @live.id, confirmation: "member/live", admitted_at: @live.admitted_at.iso8601(6) } },
      headers: { "Referer" => agents_url(@organization) }
    assert_redirected_to agents_url(@organization)
    assert_not @live.reload.admitted?
    follow_redirect!
    assert_select "form[action=?]", retirement_path(@organization, "member", "live"), count: 0
  end

  test "the organization's network agent has no retire button and cannot be retired" do
    network = A2a::Network.ensure!(@organization)
    address = [ network.prefix, network.handle ]
    sign_in(@boss)
    get agents_path(@organization)
    assert_select "a[href=?]", agent_path(@organization, *address)
    assert_select "form[action=?]", retirement_path(@organization, *address), count: 0
    assert_select "form[action=?]", retirement_path(@organization, "member", "live")

    get retirement_path(@organization, *address)
    assert_response :not_found
    post retirement_path(@organization, *address),
      params: { retirement: { agent_id: network.id, confirmation: network.qualified_handle, admitted_at: network.admitted_at.iso8601(6) } }
    assert_response :not_found
    assert network.reload.admitted?
  end

  test "a declined waiting agent leaves the waiting list" do
    sign_in(@boss)
    delete pending_agent_path(@organization, @waiting), headers: { "Referer" => agents_url(@organization) }
    assert_redirected_to agents_url(@organization)
    assert @waiting.reload.declined_at
    follow_redirect!
    assert_select "#waiting_title", count: 0
  end

  test "members see neither the waiting list nor retire buttons" do
    sign_in(@member)
    get agents_path(@organization)
    assert_response :success
    assert_select "#waiting_title", count: 0
    assert_select "form[action*='/retirement']", count: 0
    assert_select "a[href=?]", agent_path(@organization, "member", "live")

    post retirement_path(@organization, "member", "live"),
      params: { retirement: { agent_id: @live.id, confirmation: "member/live", admitted_at: @live.admitted_at.iso8601(6) } }
    assert_response :not_found
    post pending_agent_approval_path(@organization, @waiting)
    assert_response :not_found
    assert @live.reload.admitted?
    assert @waiting.reload.pending?
  end

  private

  def sign_in(user)
    sign_in_via_ajent(subject: user.ajent_sub, email: user.email, name: user.handle)
  end
end
