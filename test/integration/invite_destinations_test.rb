require "test_helper"

class InviteDestinationAccessTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(ajent_sub: "invite-owner", handle: "invite-owner", email: "owner@example.test")
    @other_owner = User.create!(ajent_sub: "other-owner", handle: "other-owner", email: "other@example.test")
    @owned = Organization.create!(name: "Owned Network")
    @member_only = Organization.create!(name: "Member Network")
    @outside = Organization.create!(name: "Outside Network")
    @owned.memberships.create!(user: @owner, role: "owner")
    @owned.memberships.create!(user: @other_owner, role: "owner")
    @member_only.memberships.create!(user: @owner, role: "member")
    @member_only.memberships.create!(user: @other_owner, role: "owner")
    @outside.memberships.create!(user: @other_owner, role: "owner")
  end

  test "the invite destination page lists exactly the current owner's networks and leaves data unchanged" do
    sign_in(@owner)
    get organization_root_path(@member_only)

    assert_no_difference [ -> { Invitation.count }, -> { Membership.count }, -> { Organization.count }, -> { Agent.count } ] do
      get "/invite_destination"
      assert_response :success
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
      assert_select "#invite_destinations a", count: 1
      assert_select "#invite_destinations a[href=?]", edit_organization_path(@owned), text: "Owned Network"
      assert_not_includes response.body, @member_only.name
      assert_not_includes response.body, @outside.name
      assert_select "#invitation_email", count: 0

      get edit_organization_path(@owned)
      assert_response :success
      assert_select "form[action=?][method=post] input[name='invitation[email]']:not([value])", invitations_path(@owned)
    end
  end

  test "signed-out and signed-in people without an owned network cannot select one" do
    assert_no_difference -> { Invitation.count } do
      get "/invite_destination"
      assert_redirected_to sign_in_path

      with_organization_creation("closed") do
        sign_in(@owner)
        @owned.memberships.find_by!(user: @owner).update!(role: "member")
        get "/invite_destination"
        assert_response :success
        assert_select "#no_invite_destinations"
        assert_select "#invite_destinations", count: 0
        assert_not_includes response.body, @owned.name
        assert_not_includes response.body, @member_only.name

        sign_in(User.create!(ajent_sub: "no-network", handle: "no-network", email: "none@example.test"))
        get "/invite_destination"
        assert_response :success
        assert_select "#no_invite_destinations"
      end
    end
  end

  test "owner rights are checked again on the settings page and on the existing POST" do
    previous = ApplicationController.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    sign_in(@owner)
    get "/invite_destination"
    assert_select "#invite_destinations a[href=?]", edit_organization_path(@owned)
    get edit_organization_path(@owned)
    token = css_select("form[action='#{invitations_path(@owned)}'] input[name='authenticity_token']").sole["value"]

    @owned.memberships.find_by!(user: @owner).update!(role: "member")
    assert_no_difference [ -> { Invitation.count }, -> { Membership.count } ] do
      get edit_organization_path(@owned)
      assert_response :not_found
      get edit_organization_path(@outside)
      assert_response :not_found
      post invitations_path(@owned), params: { authenticity_token: token, invitation: { email: "typed@example.test" } }, headers: { "Sec-Fetch-Site" => "same-origin" }
      assert_response :not_found
    end
  ensure
    ApplicationController.allow_forgery_protection = previous
  end

  test "ordinary root and legacy organization redirects do not open the picker" do
    sign_in(@owner)
    get "/"
    assert_redirected_to organization_root_path(@owned)
    get "/?invite_review=1"
    assert_response :redirect
    assert_match %r{\A/#{@owned.slug}/?\?invite_review=1\z}, URI(response.location).request_uri
    get "/organization/edit?invite_review=1"
    assert_redirected_to "#{edit_organization_path(@owned)}?invite_review=1"
  end

  private

  def sign_in(user)
    sign_in_via_ajent(subject: user.ajent_sub, email: user.email, name: user.handle)
  end
end
