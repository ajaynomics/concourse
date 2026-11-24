require "test_helper"

# Capybara's default server is Puma. This app is Falcon.
Capybara.register_server :falcon do |app, port, host|
  require "rackup/handler/falcon"
  Rackup::Handler::Falcon.run(app, Host: host, Port: port)
end
Capybara.server = :falcon

# Chrome 158 refuses a DevTools storage clear for the origin "*", which Capybara 3.40
# sends on every session reset (teamcapybara/capybara#2865). Clear cookies everywhere
# and storage for the app's own origin, the only one these tests visit. Remove once
# Capybara ships a fix.
module ClearAppOriginOnReset
  def execute_cdp(cmd, params = {})
    return super unless cmd == "Storage.clearDataForOrigin" && params[:origin] == "*"

    super("Network.clearBrowserCookies")
    storage = params[:storageTypes].to_s.split(",") - [ "cookies" ]
    origin = Capybara.current_session.server&.base_url
    super(cmd, origin: origin, storageTypes: storage.join(",")) if origin && storage.any?
  end
end
Capybara::Selenium::Driver::ChromeDriver.prepend(ClearAppOriginOnReset)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Phone first: the owner pages are designed for it, and the tab bar only
  # exists below the sm breakpoint.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ] do |options|
    options.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"].present?
    # CI runs as root in a container: Chrome's sandbox refuses root, and the
    # container's /dev/shm is too small for it.
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end

  include OmniAuthTestHelper

  def sign_in_as(subject:, email:, name:, email_verified: true)
    mock_ajent_auth(subject: subject, email: email, name: name, email_verified: email_verified)
    visit "/auth/ajent/callback"
  end

  # A frame that advances the URL finishes with a page visit after it renders,
  # and the back button can only restore the page before it once that visit
  # has loaded at path and Turbo has cached the old page, a tick later. A
  # person never presses back that fast; a test does.
  def finishing_turbo_visit_to(path)
    execute_script <<~JS, path
      window.turboLoaded = new Promise(resolve => {
        addEventListener("turbo:load", function loaded() {
          if (location.pathname + location.search != arguments[0]) return
          removeEventListener("turbo:load", loaded)
          setTimeout(resolve)
        }.bind(null, arguments[0]))
      })
    JS
    yield
    evaluate_async_script "window.turboLoaded.then(() => arguments[0]())"
  end
end
