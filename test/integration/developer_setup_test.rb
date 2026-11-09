require "test_helper"

class DeveloperSetupTest < ActionDispatch::IntegrationTest
  STATE = "setup_nonce_0123456789-ABCDEFGHIJK"
  FORM_HEADERS = { "CONTENT_TYPE" => "application/x-www-form-urlencoded", "HTTP_SEC_FETCH_SITE" => "same-origin", "HTTP_ORIGIN" => "https://www.example.com" }.freeze

  test "setup explains that owner approval still needs the terminal continuation" do
    sign_in_browser
    start_setup
    assert_select "p", text: /Approval alone does not finish terminal setup/
    assert_select "p", text: /organization owner.*approve.*Continue in terminal/
    assert session[Developer::SetupContinuation::SESSION_KEY]
    submit_rendered_form("organization_slug", @organization.slug)
    assert_completion(@organization)
  end


  test "late background responses cannot overwrite a newer setup continuation" do
    paths = [ pwa_service_worker_path(format: :js), pwa_service_worker_path, pwa_manifest_path(format: :json), pwa_manifest_path, "/cable" ]
    paths.product([ :after_setup, :before_setup ]).each do |path, receipt_order|
      sign_in_browser
      background = open_session
      background.https!
      key = Rails.application.config.session_options.fetch(:key)
      background.cookies[key] = cookies[key]
      background.get path
      assert_equal 200, background.response.status unless path == "/cable"
      # Generate the real response with the old cookie, but delay its receipt.
      # No threads or sleeps: browsers apply Set-Cookie in response order.
      held_cookies = Array(background.response.headers["Set-Cookie"])
      held_cookies.each { |cookie| cookies.merge(cookie, URI("https://www.example.com")) } if receipt_order == :before_setup
      start_setup
      fields = rendered_fields("organization_slug", @organization.slug)
      held_cookies.each { |cookie| cookies.merge(cookie, URI("https://www.example.com")) } if receipt_order == :after_setup
      post developer_setup_path, params: URI.encode_www_form(fields), headers: FORM_HEADERS
      assert_completion(@organization)
      assert_nil session[Developer::SetupContinuation::SESSION_KEY]
      assert held_cookies.none? { |cookie| cookie.start_with?("#{key}=") }, "#{path} must not replace the browser session"
    end
    assert_equal 12.hours, Rails.application.config.session_options.fetch(:expire_after)
    assert_equal 12.hours, Rails.application.config.x.session_max_age
  end

  test "only a vetted signed-in live continuation extends this document's form-action" do
    get developer_setup_path
    baseline = csp_directives
    assert_no_loopback
    start_setup
    assert_redirected_to sign_in_path
    assert_no_loopback
    sign_in_browser
    start_setup
    expected = baseline.merge("form-action" => baseline.fetch("form-action") + [ "http://127.0.0.1:49152" ])
    assert_equal expected, csp_directives
    submit_rendered_form("organization_slug", @organization.slug)
    assert_completion(@organization)
    assert_equal expected, csp_directives
    post_form(organization_slug: @organization.slug)
    assert_response :unprocessable_entity
    assert_no_loopback
    get developer_setup_path
    assert_no_loopback
    start_setup
    travel 10.minutes do
      get developer_setup_path
      assert_no_loopback
    end
    start_setup
    get developer_setup_path, params: { port: "49153", state: STATE, redirect_uri: "http://localhost:49153/evil" }
    assert_response :bad_request
    assert_no_loopback
    get sign_in_path
    assert_equal baseline, csp_directives
    get root_path
    assert_equal baseline, csp_directives
  end

  test "creation and existing selection preserve long slugs including uniqueness suffixes" do
    @settings.organization_creation = "open"
    sign_in_browser
    [ 101, 120, 123 ].each do |length|
      name = (length == 123 ? "s" * 120 : "x" * length)
      # Three foundings in one test; the daily founding limit is not under test.
      @user.memberships.update_all(created_at: 2.days.ago)
      if length == 123
        Organization.create!(name: name)
        (2..9).each { |suffix| Organization.create!(name: name, slug: "#{name}-#{suffix}") }
      end
      start_setup
      submit_rendered_form("organization_name", name)
      organization = @user.organizations.order(:id).last
      assert_equal length, organization.slug.length
      assert_completion(organization)
      start_setup
      submit_rendered_form("organization_slug", organization.slug)
      assert_completion(organization)
    end
  end

  test "Rack's retained encoded form works after raw input is consumed and still rejects duplicates" do
    sign_in_browser
    start_setup
    fields = rendered_fields("organization_slug", @organization.slug)
    encoded = URI.encode_www_form(fields)
    post developer_setup_path, params: "#{encoded}&organization_slug=#{@organization.slug}", headers: FORM_HEADERS, env: { "RAW_POST_DATA" => nil }
    assert_response :bad_request
    assert_private_response
    assert session[Developer::SetupContinuation::SESSION_KEY]
    post developer_setup_path, params: encoded, headers: FORM_HEADERS, env: { "RAW_POST_DATA" => nil }
    assert_completion(@organization)
  end

  setup do
    @settings = Rails.application.config.x.concourse
    @previous_release = @settings.release_line
    @previous_creation = @settings.organization_creation
    @settings.release_line = 3
    @settings.organization_creation = "closed"
    @previous_csrf = Developer::SetupsController.allow_forgery_protection
    @previous_origin_check = Developer::SetupsController.forgery_protection_origin_check
    Developer::SetupsController.allow_forgery_protection = true
    Developer::SetupsController.forgery_protection_origin_check = true
    @previous_callback_hook = OmniAuth.config.before_callback_phase
    @organization = Organization.create!(name: "Browser team", email_domains: "example.test")
    Current.reset
    https!
  end

  teardown do
    @settings.release_line = @previous_release
    @settings.organization_creation = @previous_creation
    Developer::SetupsController.allow_forgery_protection = @previous_csrf
    Developer::SetupsController.forgery_protection_origin_check = @previous_origin_check
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:ajent] = nil
    OmniAuth.config.before_callback_phase = @previous_callback_hook
    Current.reset
  end

  test "a bare unsigned GET provides a guide and cannot arm a callback" do
    get developer_setup_path
    assert_response :success
    assert_private_response
    assert_select "a[href='#{join_path}']", "Read the connection guide"
    assert_select "form[action='#{developer_setup_path}']", count: 0
    assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    post_form(organization_slug: @organization.slug)
    assert_response :unprocessable_entity
    assert_private_response
    assert_nil response.headers["Location"]
  end

  test "unsigned setup stores only vetted hints and returns through the OIDC session reset" do
    start_setup
    assert_redirected_to sign_in_path
    assert_private_response
    continuation = session[Developer::SetupContinuation::SESSION_KEY].dup
    old_session_id = session.id
    mock_ajent_auth(subject: "browser-owner", email: "browser@example.test")
    OmniAuth.config.before_callback_phase = ->(env) do
      env["rack.session"]["omniauth.nonce"] = "old-nonce"
      env["rack.session"]["return_to"] = "https://evil.example"
    end
    assert_no_difference [ -> { Agent.count }, -> { Agent::ClientBinding.count } ] do
      get "/auth/ajent/callback"
    end
    assert_redirected_to developer_setup_path
    assert_not_equal old_session_id, session.id
    assert_equal continuation, session[Developer::SetupContinuation::SESSION_KEY]
    assert_nil session["omniauth.nonce"]
    assert_nil session["return_to"]
    assert_equal User.find_by!(ajent_sub: "browser-owner").id, session[:user_id]
    follow_redirect!
    assert_response :success
    assert_private_response
    assert_select "select[name='organization_slug'] option[selected]", @organization.name
    assert_select "p", /may differ from this browser account/
    submit_rendered_form("organization_slug", @organization.slug)
    assert_completion(@organization)
  end

  test "the actual membership form submits compatible fields without creating agents or bindings" do
    sign_in_browser
    start_setup
    assert_private_response
    user_attributes = @user.reload.attributes
    assert_no_difference [ -> { Organization.count }, -> { User.count }, -> { Membership.count }, -> { Agent.count }, -> { Agent::ClientBinding.count } ] do
      submit_rendered_form("organization_slug", @organization.slug)
    end
    assert_equal user_attributes, @user.reload.attributes
    assert_completion(@organization)
    assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    post_form(organization_slug: @organization.slug)
    assert_response :unprocessable_entity
    assert_private_response
    assert_nil response.headers["Location"]
  end

  test "multiple memberships have no default even when the regular web session has an organization" do
    sign_in_browser
    second = Organization.create!(name: "Second team")
    @user.memberships.create!(organization: second)
    start_setup
    assert_equal @organization.id, session[:organization_id]
    assert_select "select[name='organization_slug'] option[selected]", count: 0
    assert_select "select[name='organization_slug'] option[value='']", "Choose an organization"
    post_form(organization_slug: "")
    assert_response :unprocessable_entity
    assert_private_response
    assert_nil response.headers["Location"]
    submit_rendered_form("organization_slug", second.slug)
    assert_completion(second)
  end

  test "a no-query GET resumes but never extends the lifetime" do
    sign_in_browser
    start_setup
    original = session[Developer::SetupContinuation::SESSION_KEY].dup
    travel 9.minutes do
      get developer_setup_path
      assert_response :success
      assert_private_response
      assert_equal original, session[Developer::SetupContinuation::SESSION_KEY]
    end
    travel 10.minutes do
      get developer_setup_path
      assert_response :success
      assert_private_response
      assert_select "a[href='#{join_path}']"
      assert_select "form[action='#{developer_setup_path}']", count: 0
      assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    end
  end

  test "an expired continuation cannot POST or survive OIDC reset" do
    sign_in_browser
    start_setup
    fields = rendered_fields("organization_slug", @organization.slug)
    travel 10.minutes do
      post developer_setup_path, params: URI.encode_www_form(fields), headers: FORM_HEADERS
      assert_response :unprocessable_entity
      assert_private_response
      assert_nil response.headers["Location"]
      assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    end
    start_setup
    travel 10.minutes do
      mock_ajent_auth(subject: "browser-owner", email: "browser@example.test")
      get "/auth/ajent/callback"
      assert_redirected_to root_path
      assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    end
  end

  test "closed creation offers no form to a signed-in nonmember and refuses forged choices" do
    sign_in_browser(email: "browser@nowhere.test")
    start_setup
    assert_response :success
    assert_private_response
    assert_select "[role='status']", /organization creation is closed/
    assert_select "form[action='#{developer_setup_path}']", count: 0
    assert_no_difference [ -> { Organization.count }, -> { Agent.count }, -> { Membership.count } ] do
      post_form(organization_name: "Unapproved team")
    end
    assert_response :forbidden
    assert_private_response
    post_form(organization_slug: @organization.slug)
    assert_response :unprocessable_entity
    assert_private_response
    assert_nil response.headers["Location"]
  end

  test "open creation's actual form makes an owner and only the required system network agent" do
    @settings.organization_creation = "open"
    sign_in_browser(email: "browser@nowhere.test")
    start_setup
    assert_select "input[name='organization_name'][maxlength='120']"
    assert_no_difference [ -> { User.count }, -> { @user.agents.count }, -> { Agent::ClientBinding.count } ] do
      assert_difference [ -> { Organization.count }, -> { Agent.count } ], 1 do
        assert_difference -> { Membership.count }, 2 do
          submit_rendered_form("organization_name", "New browser team")
        end
      end
    end
    organization = Organization.find_by!(slug: "new-browser-team")
    assert_completion(organization)
    assert_equal "owner", @user.membership_in(organization).role
    assert_empty organization.email_domain_list
    assert_equal [ User.system.id ], organization.agents.pluck(:owner_id)
    assert A2a::Network.agent?(organization.agents.sole)
  end

  test "creation validation and a closed setting recheck retain the continuation without creating anything" do
    @settings.organization_creation = "open"
    sign_in_browser
    start_setup
    fields = rendered_fields("organization_name", "x" * 121)
    assert_no_difference [ -> { Organization.count }, -> { Agent.count }, -> { Membership.count } ] do
      post developer_setup_path, params: URI.encode_www_form(fields), headers: FORM_HEADERS
    end
    assert_response :unprocessable_entity
    assert_private_response
    assert session[Developer::SetupContinuation::SESSION_KEY]
    @settings.organization_creation = "closed"
    fields["organization_name"] = "Closed since rendering"
    post developer_setup_path, params: URI.encode_www_form(fields), headers: FORM_HEADERS
    assert_response :forbidden
    assert_private_response
    assert_nil response.headers["Location"]
  end

  test "choosing and creating simultaneously is refused" do
    @settings.organization_creation = "open"
    sign_in_browser
    start_setup
    assert_no_difference [ -> { Organization.count }, -> { Agent.count } ] do
      post_form(organization_slug: @organization.slug, organization_name: "Another team")
    end
    assert_response :unprocessable_entity
    assert_private_response
    assert_nil response.headers["Location"]
  end

  test "membership is re-queried at POST and removals veto even a stale membership row" do
    sign_in_browser
    start_setup
    fields = rendered_fields("organization_slug", @organization.slug)
    @user.membership_in(@organization).remove
    post developer_setup_path, params: URI.encode_www_form(fields), headers: FORM_HEADERS
    assert_response :unprocessable_entity
    assert_private_response
    assert_nil response.headers["Location"]
    @user.memberships.create!(organization: @organization)
    post developer_setup_path, params: URI.encode_www_form(fields), headers: FORM_HEADERS
    assert_response :unprocessable_entity
    assert_private_response
    assert_select "option[value='#{@organization.slug}']", count: 0
    assert_nil response.headers["Location"]
  end

  test "OIDC web admission still requires a verified domain and never restores a removed member" do
    @organization.removals.create!(user: User.create!(ajent_sub: "browser-owner", handle: "browser"))
    start_setup
    mock_ajent_auth(subject: "browser-owner", email: "browser@example.test")
    get "/auth/ajent/callback"
    follow_redirect!
    assert_response :success
    assert_empty User.find_by!(ajent_sub: "browser-owner").organizations
    assert_select "form[action='#{developer_setup_path}']", count: 0
    delete sign_out_path
    start_setup
    mock_ajent_auth(subject: "unverified", email: "unverified@example.test", email_verified: false)
    get "/auth/ajent/callback"
    follow_redirect!
    assert_response :success
    assert_private_response
    assert_empty User.find_by!(ajent_sub: "unverified").organizations
    assert_select "form[action='#{developer_setup_path}']", count: 0
  end

  test "Rails header-based CSRF and origin checks reject cross-site and missing browser evidence" do
    sign_in_browser
    start_setup
    valid_fields = rendered_fields("organization_slug", @organization.slug)
    [ "cross-site", "none", nil ].each do |site|
      post developer_setup_path, params: URI.encode_www_form(valid_fields), headers: FORM_HEADERS.merge("HTTP_SEC_FETCH_SITE" => site)
      assert_response :unprocessable_entity
      assert_private_response
      assert_nil response.headers["Location"]
      assert session[Developer::SetupContinuation::SESSION_KEY]
    end
    [ "https://evil.example", "null", "http://127.0.0.1:49152" ].each do |origin|
      post developer_setup_path, params: URI.encode_www_form(valid_fields), headers: FORM_HEADERS.merge("HTTP_ORIGIN" => origin)
      assert_response :unprocessable_entity
      assert_private_response
      assert_nil response.headers["Location"]
    end
    post developer_setup_path, params: URI.encode_www_form(valid_fields), headers: FORM_HEADERS
    assert_completion(@organization)
  end

  test "the optional Rails legacy-token fallback still rejects missing and invalid CSRF tokens" do
    previous = Developer::SetupsController.forgery_protection_verification_strategy
    Developer::SetupsController.forgery_protection_verification_strategy = :header_or_legacy_token
    sign_in_browser
    start_setup
    valid_fields = rendered_fields("organization_slug", @organization.slug)
    headers = FORM_HEADERS.merge("HTTP_SEC_FETCH_SITE" => "none")
    [ valid_fields.except("authenticity_token"), valid_fields.merge("authenticity_token" => "forged") ].each do |fields|
      post developer_setup_path, params: URI.encode_www_form(fields), headers: headers
      assert_response :unprocessable_entity
      assert_private_response
      assert_nil response.headers["Location"]
      assert session[Developer::SetupContinuation::SESSION_KEY]
    end
    post developer_setup_path, params: URI.encode_www_form(valid_fields), headers: headers
    assert_completion(@organization)
  ensure
    Developer::SetupsController.forgery_protection_verification_strategy = previous
  end

  test "unsigned POST cannot use a bearer token as a browser identity" do
    start_setup
    post_form({ organization_slug: @organization.slug }, headers: { "Authorization" => "Bearer unused-token" })
    assert_redirected_to sign_in_path
    assert_private_response
    assert_not_requested :post, AgentTokens::INTROSPECT
  end

  test "GET and HEAD reject malformed query fields and clear prior hints" do
    sign_in_browser
    queries = [
      "port=49152&port=49153&state=#{STATE}", "port=49152&state=#{STATE}&state=#{STATE}",
      "port[]=49152&state=#{STATE}", "port=49152&state[]=#{STATE}",
      "port=49152&port[x]=1&state=#{STATE}", "port=49152&state=#{STATE}%", "port=49152&state=#{STATE}%GG",
      "port=49152&state=#{STATE}%FF", "port=49152&%70ort=49153&state=#{STATE}",
      "port=49152&state=#{STATE}&redirect_uri=https%3A%2F%2Fevil.example",
      "port=49152&state=#{STATE}&organization=#{@organization.slug}", "port=49152&state=#{STATE}&client_id=forged",
      "port=49152&state=#{STATE}&owner=forged", "port=49152&state=#{STATE}&padding=#{'x' * 4096}"
    ]
    queries.product(%i[get head]).each do |query, verb|
      start_setup
      public_send verb, developer_setup_path, env: { "QUERY_STRING" => query }
      assert_equal query, request.query_string
      assert_response :bad_request
      assert_private_response
      assert_nil response.headers["Location"]
      assert_nil session[Developer::SetupContinuation::SESSION_KEY]
      assert_empty response.body if verb == :head
    end
  end

  test "GET rejects missing noncanonical or out-of-range port and unsafe or incorrectly sized state" do
    sign_in_browser
    [ nil, "", "0", "80", "1023", "65536", "99999", "049152", "+49152", "49152.0", "49152@evil.example", "49152/path" ].each do |port|
      get developer_setup_path, params: { port: port, state: STATE }.compact
      assert_response :bad_request
      assert_private_response
      assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    end
    [ nil, "", "a" * 31, "a" * 129, "a" * 31 + "/", "a" * 31 + "=", "a" * 31 + "+", STATE + "\n", "é" * 32 ].each do |state|
      get developer_setup_path, params: { port: "49152", state: state }.compact
      assert_response :bad_request
      assert_private_response
      assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    end
  end

  test "valid port and state boundaries return only the fixed loopback hint" do
    sign_in_browser
    [ [ "1024", "a" * 32 ], [ "65535", "_-" * 64 ] ].each do |port, state|
      start_setup(port: port, state: state)
      submit_rendered_form("organization_slug", @organization.slug)
      assert_completion(@organization, port: port, state: state)
    end
  end

  test "POST rejects duplicate bracket malformed percent and extra authority or callback fields" do
    sign_in_browser
    start_setup
    base = URI.encode_www_form(rendered_fields("organization_slug", @organization.slug))
    bodies = [
      "#{base}&organization_slug=#{@organization.slug}", "#{base}&organization_name[]=team",
      "#{base}&organization_slug[x]=team", "#{base}&organization_name=bad%", "#{base}&organization_name=bad%GG",
      "#{base}&organization_name=bad%FF", "#{base}&organization_%73lug=#{@organization.slug}",
      "#{base}&port=49153", "#{base}&state=#{STATE}", "#{base}&redirect_uri=https://evil.example",
      "#{base}&client_id=forged", "#{base}&owner=forged", "#{base}&organization_name=#{'x' * 4096}"
    ]
    bodies.each do |body|
      assert_no_difference [ -> { Organization.count }, -> { Agent.count }, -> { Agent::ClientBinding.count } ] do
        post developer_setup_path, params: body, headers: FORM_HEADERS
      end
      assert_response :bad_request
      assert_private_response
      assert_nil response.headers["Location"]
      assert session[Developer::SetupContinuation::SESSION_KEY]
    end
  end

  test "POST query strings and non-form content types cannot override the continuation" do
    sign_in_browser
    start_setup
    fields = rendered_fields("organization_slug", @organization.slug)
    post "#{developer_setup_path}?port=49153", params: URI.encode_www_form(fields), headers: FORM_HEADERS
    assert_response :bad_request
    assert_private_response
    post developer_setup_path, params: fields.to_json, headers: FORM_HEADERS.merge("CONTENT_TYPE" => "application/json", "X-CSRF-Token" => fields.fetch("authenticity_token"))
    assert_response :bad_request
    assert_private_response
    assert_nil response.headers["Location"]
  end

  test "a replacement link invalidates the older continuation" do
    sign_in_browser
    start_setup
    start_setup(port: "49153", state: "b" * 32)
    submit_rendered_form("organization_slug", @organization.slug)
    assert_completion(@organization, port: "49153", state: "b" * 32)
  end

  test "logout and failed authentication discard setup" do
    sign_in_browser
    start_setup
    delete sign_out_path
    assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    start_setup
    mock_ajent_auth(subject: "")
    get "/auth/ajent/callback"
    assert_redirected_to sign_in_path
    assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    start_setup
    get "/auth/failure"
    assert_redirected_to sign_in_path
    assert_nil session[Developer::SetupContinuation::SESSION_KEY]
  end

  test "v1 disables the bridge and preserves regular sign-in behavior" do
    @settings.release_line = 1
    get developer_setup_path, params: { port: "49152", state: STATE }
    assert_response :not_found
    assert_private_response
    assert_nil session[Developer::SetupContinuation::SESSION_KEY]
    post developer_setup_path, params: "organization_slug=#{@organization.slug}", headers: FORM_HEADERS
    assert_response :not_found
    assert_private_response
    mock_ajent_auth(subject: "browser-owner", email: "browser@example.test")
    get "/auth/ajent/callback"
    assert_redirected_to root_path
    assert_nil session[Developer::SetupContinuation::SESSION_KEY]
  end

  test "normal v3 sign-in has no setup redirect and no user-agent-specific enrollment" do
    [ "concourse-cli/1.0", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36" ].each do |agent|
      mock_ajent_auth(subject: "browser-owner", email: "browser@example.test")
      assert_no_difference [ -> { Agent.count }, -> { Agent::ClientBinding.count } ] do
        get "/auth/ajent/callback", headers: { "HTTP_USER_AGENT" => agent }
      end
      assert_redirected_to root_path
      start_setup(headers: { "HTTP_USER_AGENT" => agent })
      assert_response :success
      submit_rendered_form("organization_slug", @organization.slug)
      assert_completion(@organization)
    end
  end

  test "OIDC reset discards malformed or authority-bearing setup session values" do
    original = Developer::SetupContinuation.start(port: "49152", state: STATE).to_h
    [ original.merge("redirect_uri" => "https://evil.example"), original.merge("owner" => "forged"),
      original.merge(state: STATE), original.merge("expires_at" => 11.minutes.from_now.to_i) ].each do |value|
      mock_ajent_auth(subject: "browser-owner", email: "browser@example.test")
      OmniAuth.config.before_callback_phase = ->(env) { env["rack.session"][Developer::SetupContinuation::SESSION_KEY] = value }
      get "/auth/ajent/callback"
      assert_redirected_to root_path
      assert_nil session[Developer::SetupContinuation::SESSION_KEY]
      assert_nil session["redirect_uri"]
    end
  end

  test "changing browser accounts rotates CSRF and checks the new account's membership" do
    previous = Developer::SetupsController.forgery_protection_verification_strategy
    Developer::SetupsController.forgery_protection_verification_strategy = :header_or_legacy_token
    headers = FORM_HEADERS.merge("HTTP_SEC_FETCH_SITE" => "none")
    sign_in_browser
    start_setup
    old_fields = rendered_fields("organization_slug", @organization.slug)
    original = session[Developer::SetupContinuation::SESSION_KEY].dup
    mock_ajent_auth(subject: "another-browser-owner", email: "another@nowhere.test")
    get "/auth/ajent/callback"
    assert_redirected_to developer_setup_path
    assert_equal original, session[Developer::SetupContinuation::SESSION_KEY]
    post developer_setup_path, params: URI.encode_www_form(old_fields), headers: headers
    assert_response :unprocessable_entity
    assert_private_response
    assert_select "[role='alert']", /form expired/
    assert_select "form[action='#{developer_setup_path}']", count: 0
    post_form(organization_slug: @organization.slug, headers: headers)
    assert_response :unprocessable_entity
    assert_private_response
    assert_select "[role='alert']", /currently belong to/
    assert_nil response.headers["Location"]
  ensure
    Developer::SetupsController.forgery_protection_verification_strategy = previous
  end

  test "a preexisting continuation is ignored by v1 sign-in" do
    start_setup
    assert session[Developer::SetupContinuation::SESSION_KEY]
    @settings.release_line = 1
    mock_ajent_auth(subject: "browser-owner", email: "browser@example.test")
    get "/auth/ajent/callback"
    assert_redirected_to root_path
    assert_nil session[Developer::SetupContinuation::SESSION_KEY]
  end

  private

  def sign_in_browser(email: "browser@example.test")
    sign_in_via_ajent(subject: "browser-owner", email: email)
    @user = User.find_by!(ajent_sub: "browser-owner")
  end

  def start_setup(port: "49152", state: STATE, headers: {})
    get developer_setup_path, params: { port: port, state: state }, headers: headers
  end

  # Submit successful HTML controls, including a named clicked submit button.
  # Hand-built params alone would miss fields Rails silently adds to forms.
  def rendered_fields(field, value)
    form = css_select("form[action='#{developer_setup_path}']").find { |node| node.at_css("[name='#{field}']") }
    assert form, "expected a rendered #{field} form"
    fields = form.css("input[name], select[name], button[type='submit'][name]").to_h do |control|
      [ control["name"], control.name == "select" ? control.at_css("option[selected]")&.[]("value").to_s : control["value"].to_s ]
    end
    assert_equal [ "authenticity_token", field ].sort, fields.keys.sort
    assert fields.fetch("authenticity_token").present?
    fields[field] = value
    fields
  end

  def submit_rendered_form(field, value)
    post developer_setup_path, params: URI.encode_www_form(rendered_fields(field, value)), headers: FORM_HEADERS
  end

  def post_form(fields = {}, headers: {}, **values)
    token = css_select("meta[name='csrf-token']").first&.[]("content")
    post developer_setup_path, params: URI.encode_www_form(fields.merge(values).merge(authenticity_token: token)), headers: FORM_HEADERS.merge(headers)
  end

  def csp_directives
    response.headers.fetch("Content-Security-Policy").split("; ").to_h do |directive|
      name, *sources = directive.split
      [ name, sources.reject { |source| source.start_with?("'nonce-") } ]
    end
  end

  def assert_no_loopback
    assert_equal Rails.application.config.content_security_policy.directives.fetch("form-action"), csp_directives.fetch("form-action")
  end

  def assert_private_response
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
  end

  def assert_completion(organization, port: "49152", state: STATE)
    assert_response :see_other
    assert_private_response
    assert_equal Rails.application.config.content_security_policy.directives.fetch("form-action") + [ "http://127.0.0.1:#{port}" ], csp_directives.fetch("form-action")
    uri = URI.parse(response.headers.fetch("Location"))
    assert_equal "http", uri.scheme
    assert_equal "127.0.0.1", uri.host
    assert_equal port.to_i, uri.port
    assert_equal "/setup-complete", uri.path
    assert_nil uri.userinfo
    assert_nil uri.fragment
    assert_equal [ [ "state", state ], [ "organization", organization.slug ] ], URI.decode_www_form(uri.query)
  end
end
