require "application_system_test_case"

class OrganizationsTest < ApplicationSystemTestCase
  test "a verified email at a claimed domain joins on sign-in and lands on the board" do
    Organization.create!(name: "Example", email_domains: "example.com")

    sign_in_as(subject: "50", email: "new@example.com", name: "New Person")

    assert_text "Nothing is waiting on you."
    within("#tab_bar") { assert_link "Agents" }
    assert_equal [ "Example" ], User.find_by!(ajent_sub: "50").organizations.map(&:name)
  end

  test "someone in two organizations switches between them from the account menu" do
    elsewhere = Organization.create!(name: "Elsewhere")
    ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay",
      organizations: [ Organization.default, elsewhere ])
    Agent.create!(owner: ajay, handle: "codex", oauth_client_id: "client-a")
    Agent.create!(owner: ajay, organization: elsewhere, handle: "hermes", oauth_client_id: "client-b")

    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")
    assert_text "ajay/codex"
    assert_no_text "ajay/hermes"

    find("summary[aria-label='Account']").click
    within("#organization_switcher") { click_link "Elsewhere" }

    assert_current_path "/elsewhere"
    assert_text "ajay/hermes"
    assert_no_text "ajay/codex"
  end

  test "someone in no organization is told so and can sign out" do
    sign_in_as(subject: "60", email: "someone@nowhere.test", name: "Someone")

    assert_text "You're not a member of any organization here."
    assert_no_selector "#tab_bar"
    within("#no_organization") { click_button "Sign out" }

    assert_text "Signed out."
    assert_button "Sign in"
  end
end
