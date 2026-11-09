require "application_system_test_case"
require "socket"
require "timeout"

class DeveloperSetupBrowserTest < ApplicationSystemTestCase
  STATE = "browser_setup_nonce_0123456789-ABCDE"

  setup do
    @settings = Rails.application.config.x.concourse
    @release, @creation = @settings.release_line, @settings.organization_creation
    @settings.release_line = 3
    @settings.organization_creation = "open"
    @csrf = Developer::SetupsController.allow_forgery_protection
    @origin_check = Developer::SetupsController.forgery_protection_origin_check
    Developer::SetupsController.allow_forgery_protection = true
    Developer::SetupsController.forgery_protection_origin_check = true
    @posts = Queue.new
    @subscription = ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
      payload = event.payload
      if payload[:controller] == "Developer::SetupsController" && payload[:method] == "POST"
        request = payload[:request]
        @posts << { origin: request.headers["Origin"], site: request.headers["Sec-Fetch-Site"], referrer: request.referrer, base_url: request.base_url, status: payload[:status] }
      end
    end
    @receiver = TCPServer.new("127.0.0.1", 0)
    @port = @receiver.addr[1]
    @callbacks = Queue.new
    @receiver_thread = Thread.new do
      loop do
        socket = @receiver.accept
        begin
          line = socket.gets
          headers = {}
          while (header = socket.gets) && header != "\r\n"
            key, value = header.split(":", 2)
            headers[key.downcase] = value.strip
          end
          path = line.split[1]
          if path.start_with?("/setup-complete?")
            @callbacks << { uri: URI.parse(path), headers: headers }
            body = "Return to the synthetic Concourse terminal."
            socket.write "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n#{body}"
          else
            socket.write "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          end
        ensure
          socket.close
        end
      end
    end
    sign_in_as(subject: "setup-browser", email: "setup@nowhere.test", name: "Setup Browser")
    @user = User.find_by!(ajent_sub: "setup-browser")
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscription) if @subscription
    @receiver_thread&.kill
    @receiver_thread&.join
    @receiver&.close
    @settings.release_line, @settings.organization_creation = @release, @creation
    Developer::SetupsController.allow_forgery_protection = @csrf
    Developer::SetupsController.forgery_protection_origin_check = @origin_check
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:ajent] = nil
    Current.reset
  end

  test "Chromium's normal membership forms reach only their exact loopback receiver with long existing slugs" do
    [ "a" * 101, "b" * 120, "#{'c' * 120}-10" ].each do |slug|
      organization = Organization.create_with_owner!(name: "Existing #{slug.length}", owner: @user)
      organization.update!(slug: slug)
      visit "#{developer_setup_path}?#{URI.encode_www_form(port: @port, state: STATE)}"
      select organization.name, from: "Your organization"
      click_button "Continue in terminal"
      assert_browser_completion(slug)
    end
  end

  test "Chromium's normal creation forms preserve 101 and 120 character names and a 123 character unique slug" do
    [ 101, 120, 123 ].each do |length|
      name = length == 123 ? "s" * 120 : "x" * length
      # Three foundings in one test; the daily founding limit is not under test.
      @user.memberships.update_all(created_at: 2.days.ago)
      if length == 123
        Organization.create!(name: name)
        (2..9).each { |suffix| Organization.create!(name: name, slug: "#{name}-#{suffix}") }
      end
      visit "#{developer_setup_path}?#{URI.encode_www_form(port: @port, state: STATE)}"
      fill_in "Create a new organization", with: name
      click_button "Create and continue in terminal"
      slug = length == 123 ? "#{name}-10" : name
      assert_browser_completion(slug)
      organization = @user.organizations.find_by!(slug: slug)
      assert_equal length, organization.slug.length
      assert_equal "owner", @user.membership_in(organization).role
    end
  end

  test "a Chromium-generated null origin is still refused even with same-origin Fetch Metadata and a valid form token" do
    organization = Organization.create_with_owner!(name: "Null origin team", owner: @user)
    visit "#{developer_setup_path}?#{URI.encode_www_form(port: @port, state: STATE)}"
    select organization.name, from: "Your organization"
    # Reproduce the old response policy in the document, without fabricating
    # HTTP headers or changing the application's CSRF verification strategy.
    execute_script <<~JS
      const meta = document.createElement('meta');
      meta.name = 'referrer';
      meta.content = 'no-referrer';
      document.head.appendChild(meta);
    JS
    click_button "Continue in terminal"
    assert_selector "[role='alert']", text: "The form expired"
    post = Timeout.timeout(5) { @posts.pop }
    assert_equal 422, post[:status]
    assert_equal "null", post[:origin]
    assert_equal "same-origin", post[:site]
    assert @callbacks.empty?
    # Rejection retains the continuation. A fresh document's policy works.
    visit developer_setup_path
    click_button "Continue in terminal"
    assert_browser_completion(organization.slug)
  end

  private

  def assert_browser_completion(slug)
    # This is a real click and Chromium-generated POST/redirect, not a request
    # helper or JS submission: both Origin:null and form-action bugs fail here.
    assert_current_path "http://127.0.0.1:#{@port}/setup-complete?#{URI.encode_www_form(state: STATE, organization: slug)}", url: true
    assert_text "Return to the synthetic Concourse terminal."
    callback = Timeout.timeout(5) { @callbacks.pop }
    assert_equal "http://127.0.0.1:#{@port}", URI.parse(page.current_url).then { |uri| "#{uri.scheme}://#{uri.host}:#{uri.port}" }
    assert_equal "/setup-complete", callback[:uri].path
    assert_equal [ [ "state", STATE ], [ "organization", slug ] ], URI.decode_www_form(callback[:uri].query)
    assert_equal "127.0.0.1:#{@port}", callback[:headers].fetch("host")
    post = Timeout.timeout(5) { @posts.pop }
    assert_equal 303, post[:status]
    assert_equal post[:base_url], post[:origin]
    assert_equal "same-origin", post[:site]
    assert_equal "#{post[:base_url]}/", post[:referrer]
    assert_equal "#{post[:base_url]}/", callback[:headers].fetch("referer")
    visit developer_setup_path
    assert_text "Start setup from your terminal"
    assert_no_selector "form[action='#{developer_setup_path}']"
  end
end
