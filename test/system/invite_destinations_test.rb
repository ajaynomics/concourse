require "application_system_test_case"

class InviteDestinationsTest < ApplicationSystemTestCase
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "an owner chooses a network and types the address into its existing invite form" do
    owner = User.create!(ajent_sub: "invite-owner", handle: "invite-owner", email: "owner@example.test")
    destination = Organization.create!(name: "Owned Network")
    destination.memberships.create!(user: owner, role: "owner")
    sign_in_as(subject: owner.ajent_sub, email: owner.email, name: "Owner")

    assert_no_difference [ -> { Invitation.count }, -> { Membership.count } ] do
      visit invite_destination_path
      within "#invite_destinations" do
        click_link "Owned Network"
      end
      assert_current_path edit_organization_path(destination)
      within "section[aria-labelledby='invitations_title']" do
        assert_field "Email", with: ""
      end
    end

    assert_no_difference -> { Membership.count } do
      within "section[aria-labelledby='invitations_title']" do
        fill_in "Email", with: "typed@example.test"
        click_button "Invite"
        assert_text "typed@example.test"
      end
    end
    assert_equal "typed@example.test", destination.invitations.sole.email
  end
end
