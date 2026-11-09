require "test_helper"

class AuthenticationTest < ActionDispatch::IntegrationTest
  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  setup do
    @organization = Organization.create!(name: "Example", email_domains: "example.com")
  end

  test "signing in creates the user, and a verified email at a claimed domain joins the organization" do
    assert_difference -> { User.count }, 1 do
      sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay Krishnan")
    end

    user = User.find_by!(ajent_sub: "42")
    assert_equal "ajay", user.handle
    assert_equal "ajay@example.com", user.email
    assert_equal "Ajay Krishnan", user.name
    assert_equal user.id, session[:user_id]
    assert_equal [ @organization ], user.organizations
    assert_equal @organization.id, session[:organization_id]
    assert_response :success
    assert_select "#awaiting_title"
  end

  test "the home page names the signed-in user once" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay Krishnan")

    assert_equal 1, response.body.scan("Signed in as").size
    assert_includes response.body, "Signed in as Ajay Krishnan"
    assert_nil flash[:notice]
  end

  test "an unverified email is signed in but joins nothing and sees no data" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", email_verified: false)

    assert_not_nil session[:user_id]
    assert_empty User.find_by!(ajent_sub: "42").organizations
    assert_response :forbidden
    assert_select "#no_organization h1", "You're not a member of any organization here."
    assert_select "#tab_bar", count: 0
    assert_select "#no_organization form[action='#{sign_out_path}']"

    get agents_path(@organization)
    assert_response :not_found
    get my_tasks_path(@organization)
    assert_response :not_found
  end

  test "with creation open, someone in no organization is offered one and becomes its owner" do
    with_organization_creation("open") do
      sign_in_via_ajent(subject: "42", email: "ajay@nowhere.test")
      assert_equal new_organization_path, path

      post organizations_path, params: { organization: { name: "Ajay's team" } }
      follow_redirect!

      organization = Organization.find_by!(slug: "ajay-s-team")
      assert_equal [ "owner" ], organization.memberships.map(&:role)
      assert_equal organization.id, session[:organization_id]
      assert_response :success
    end
  end

  test "with creation open, a person cannot found organizations without limit" do
    with_organization_creation("open") do
      sign_in_via_ajent(subject: "42", email: "ajay@nowhere.test")
      Organization::FOUNDING_LIMIT.times do |index|
        post organizations_path, params: { organization: { name: "Team #{index}" } }
        assert_response :see_other
      end

      assert_no_difference -> { Organization.count } do
        post organizations_path, params: { organization: { name: "One too many" } }
      end
      assert_response :unprocessable_content
      assert_includes response.body, "at most #{Organization::FOUNDING_LIMIT} organizations a day"
    end
  end

  test "with creation closed, nobody creates an organization on the web" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com")

    get new_organization_path
    assert_response :not_found
    assert_no_difference -> { Organization.count } do
      post organizations_path, params: { organization: { name: "Mine" } }
    end
    assert_response :not_found
  end

  test "a second sign-in matches the subject and does not mint another user" do
    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay")

    assert_no_difference -> { User.count } do
      sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay Krishnan")
    end

    assert_equal "Ajay Krishnan", User.find_by!(ajent_sub: "42").name
  end

  test "a callback with no subject mints nothing" do
    assert_no_difference -> { User.count } do
      mock_ajent_auth(subject: "")
      get "/auth/ajent/callback"
    end

    assert_redirected_to sign_in_path
    assert_equal "Sign-in didn't finish. Try again.", flash[:alert]
    assert_nil session[:user_id]
  end

  test "an unauthenticated visitor is sent to sign in" do
    get root_path
    assert_redirected_to sign_in_path
  end

  test "a web session expires after twelve hours" do
    sign_in_via_ajent
    assert_equal User.find_by!(ajent_sub: "42").id, session[:user_id]

    travel 13.hours do
      get root_path
      assert_redirected_to sign_in_path
      assert_nil session[:user_id]
    end
  end

  test "signing out clears the session" do
    sign_in_via_ajent
    assert_not_nil session[:user_id]

    delete sign_out_path
    assert_nil session[:user_id]
    assert_redirected_to sign_in_path
  end

  test "the sign-in request phase rejects GET" do
    assert_equal [ :post ], OmniAuth.config.allowed_request_methods
  end

  test "a failed sign-in clears the attempt instead of leaving it to be replayed" do
    OmniAuth.config.before_request_phase = ->(env) { env["rack.session"]["omniauth.nonce"] = "single-use" }
    mock_ajent_auth(subject: "")
    get "/auth/ajent/callback"

    assert_nil session["omniauth.nonce"]
  ensure
    OmniAuth.config.before_request_phase = nil
  end

  test "web sign-in fills the details of a user first seen from a token" do
    User.find_or_create_from_subject!(ajent_sub: "42")
    assert_equal "sub-42", User.find_by!(ajent_sub: "42").handle

    sign_in_via_ajent(subject: "42", email: "ajay@example.com", name: "Ajay Krishnan")

    user = User.find_by!(ajent_sub: "42")
    assert_equal "ajay", user.handle
    assert_equal "ajay@example.com", user.email
    assert_equal "Ajay Krishnan", user.name
  end
end
