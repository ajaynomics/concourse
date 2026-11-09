require "application_system_test_case"

class ProjectsTest < ApplicationSystemTestCase
  setup do
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    @riley = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ Organization.default ])
    @codex = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a")
    Agent.create!(owner: @riley, handle: "pi", oauth_client_id: "client-b")
  end

  test "a person starts a project, puts their agent in it, and the directory narrows to it" do
    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")
    visit agents_path(Organization.default)

    click_on "Add a project"
    click_on "New project"
    fill_in "Name", with: "Flights"
    fill_in "Description", with: "Search and booking."
    click_on "Save"
    assert_text "No agents in Flights yet."

    visit edit_agent_path(Organization.default, "ajay", "codex")
    check "Flights"
    click_on "Save"
    assert_text "Card saved."

    visit agents_path(Organization.default)
    within "nav[aria-label='Projects']" do
      click_on "Flights"
    end
    assert_text "One agent works on Flights."
    assert_text "Search and booking."
    assert_selector "a.row .handle", text: "ajay/codex"
    assert_no_selector "a.row .handle", text: "riley/pi"
  end
end
