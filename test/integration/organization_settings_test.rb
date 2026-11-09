require "test_helper"

class OrganizationSettingsTest < ActionDispatch::IntegrationTest
  setup do
    @organization = Organization.create!(name: "Acme")
    @owner = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay")
    @member = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ @organization ])
    @organization.memberships.create!(user: @owner, role: "owner")
  end

  test "an owner edits the name and email domains and sees the members" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    get edit_organization_path(@organization)
    assert_response :success
    assert_select "li", text: /Riley/

    patch organization_path(@organization), params: { organization: { name: "Acme Labs", email_domains: "@Example.com" } }
    assert_redirected_to edit_organization_path(@organization)
    assert_equal [ "Acme Labs", "example.com" ], @organization.reload.values_at(:name, :email_domains)

    patch organization_path(@organization), params: { organization: { name: "Acme Labs", email_domains: "not a domain" } }
    assert_response :unprocessable_content
  end

  test "an owner lets apps join as agents, and the change is logged without content" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")
    get edit_organization_path(@organization)
    assert_select "input[type=checkbox][name='organization[machine_clients]']:not([checked])"
    assert_select "label", text: /Let apps join as agents/

    events = nil
    capture_events("concourse.organization.machine_clients_changed") do |captured|
      patch organization_path(@organization), params: { organization: { machine_clients: "1" } }
      patch organization_path(@organization), params: { organization: { name: "Acme", machine_clients: "1" } }
      patch organization_path(@organization), params: { organization: { machine_clients: "0" } }
      events = captured
    end
    assert_redirected_to edit_organization_path(@organization)
    assert_not @organization.reload.machine_clients?
    assert_equal [ true, false ].map { |enabled| { organization: "acme", enabled: enabled, user_id: @owner.id } },
      events.map { |event| event[:payload] }
  end

  test "the legacy organization offers no machine client setting and refuses one" do
    settings = Rails.application.config.x.concourse
    previous = settings.legacy_organization
    settings.legacy_organization = @organization.slug
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    get edit_organization_path(@organization)
    assert_select "input[name='organization[machine_clients]']", count: 0
    patch organization_path(@organization), params: { organization: { machine_clients: "1" } }
    assert_response :unprocessable_content
    assert_not @organization.reload.machine_clients?
  ensure
    settings.legacy_organization = previous
  end

  test "a member has no settings page" do
    sign_in_via_ajent(subject: "7", email: "riley@example.com", name: "Riley")

    get edit_organization_path(@organization)
    assert_response :not_found
    patch organization_path(@organization), params: { organization: { name: "Mine", machine_clients: "1" } }
    assert_response :not_found
    assert_not @organization.reload.machine_clients?
    delete membership_path(@organization, @organization.memberships.find_by!(user: @owner))
    assert_response :not_found
    assert_equal "Acme", @organization.reload.name
  end

  test "an owner removes a member but never the last owner" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    delete membership_path(@organization, @organization.memberships.find_by!(user: @member))
    assert_redirected_to edit_organization_path(@organization)
    assert_not @member.organizations.reload.include?(@organization)

    delete membership_path(@organization, @organization.memberships.find_by!(user: @owner))
    assert_redirected_to edit_organization_path(@organization)
    assert_equal "The organization's last owner can't be removed.", flash[:alert]
    assert_equal [ @owner ], @organization.users.to_a
  end

  test "an owner moves an agent to another of their organizations once its tasks are done" do
    elsewhere = Organization.create!(name: "Elsewhere")
    elsewhere.memberships.create!(user: @owner)
    codex = Agent.create!(owner: @owner, organization: @organization, handle: "codex", oauth_client_id: "client-a")
    pi = Agent.create!(owner: @member, handle: "pi", oauth_client_id: "client-b")
    task = Task.open!(recipient: pi, caller: codex)
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    get edit_agent_path(@organization, "ajay", "codex")
    assert_select "select[name='agent[organization_id]'] option", 2

    patch agent_path(@organization, "ajay", "codex"), params: { agent: { name: "Codex", description: "", organization_id: elsewhere.id } }
    assert_response :unprocessable_content
    assert_equal @organization, codex.reload.organization

    task.transition_to!("TASK_STATE_COMPLETED", by: pi)
    patch agent_path(@organization, "ajay", "codex"), params: { agent: { name: "Codex", description: "", organization_id: elsewhere.id } }
    assert_redirected_to agent_path(elsewhere, "ajay", "codex")
    assert_equal elsewhere, codex.reload.organization
    follow_redirect!
    assert_equal elsewhere.id, session[:organization_id]

    stranger = Organization.create!(name: "Stranger")
    patch agent_path(elsewhere, "ajay", "codex"), params: { agent: { organization_id: stranger.id } }
    assert_response :unprocessable_content
    assert_equal elsewhere, codex.reload.organization
  end
end
