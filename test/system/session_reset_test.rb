require "application_system_test_case"

# Chrome 158 refuses a DevTools storage clear for the origin "*", which Capybara 3.40
# sends on every session reset (teamcapybara/capybara#2865). Every system test then
# errored in teardown with "invalid argument: * is not a valid URL".
class SessionResetTest < ApplicationSystemTestCase
  test "a reset clears cookies and the app's storage without the wildcard origin Chrome 158 refuses" do
    visit terms_path
    execute_script "localStorage.setItem('left-behind', 'yes')"
    execute_script "document.cookie = 'left-behind=yes; path=/'"
    origins = []
    page.driver.browser.singleton_class.prepend(Module.new do
      define_method(:execute_cdp) { |cmd, **params| origins << params[:origin] if cmd == "Storage.clearDataForOrigin"; super(cmd, **params) }
    end)

    Capybara.reset_sessions!

    assert_not_includes origins, "*"
    assert_not_includes page.driver.browser.execute_cdp("Network.getAllCookies")["cookies"].pluck("name"), "left-behind"
    visit terms_path
    assert_nil evaluate_script("localStorage.getItem('left-behind')")
  end
end
