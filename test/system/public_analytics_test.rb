require "application_system_test_case"

class PublicAnalyticsBrowserTest < ApplicationSystemTestCase
  setup do
    @release = Rails.application.config.x.concourse.release_line
    @site_id = Rails.application.config.x.analytics.site_id
    Rails.application.config.x.concourse.release_line = 3
    Rails.application.config.x.analytics.site_id = "public-site"
    page.driver.browser.execute_cdp("Network.enable")
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [ "https://rybbit.example.com/*" ])
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @release
    Rails.application.config.x.analytics.site_id = @site_id
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "a tracked public document cannot stay alive in the owner picker" do
    owner = User.create!(ajent_sub: "public-analytics-owner", handle: "owner", email: "owner@example.test")
    organization = Organization.create!(name: "Owned Network")
    organization.memberships.create!(user: owner, role: :owner)
    mock_ajent_auth(subject: owner.ajent_sub, email: owner.email)

    visit sign_in_path
    assert_selector "script[data-site-id=public-site]", visible: :all
    execute_script "window.publicAnalyticsDocument = true"
    # Establish a synthetic session without replacing the public document. A
    # programmatic Turbo visit then exercises the tracked-head reload fence.
    evaluate_async_script <<~JS
      const done = arguments[0];
      fetch('/auth/ajent/callback', { redirect: 'manual' }).then(() => done());
    JS
    execute_script "Turbo.visit(arguments[0])", invite_destination_path

    assert_current_path invite_destination_path
    assert_selector "#invite_destinations", text: "Owned Network"
    assert_no_selector "script[data-site-id]", visible: :all
    assert_nil evaluate_script("window.publicAnalyticsDocument")
  end
end
