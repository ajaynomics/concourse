require "application_system_test_case"

class PublicPagesTest < ApplicationSystemTestCase
  teardown do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    page.driver.browser.manage.window.resize_to(390, 844)
  end

  %w[light dark].each do |scheme|
    test "public legal pages and footer are readable in #{scheme}" do
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
        { name: "prefers-color-scheme", value: scheme },
        { name: "prefers-reduced-motion", value: "reduce" }
      ])
      [ [ 390, 844 ], [ 1280, 900 ] ].each do |width, height|
        page.driver.browser.manage.window.resize_to(width, height)
        [ sign_in_path, terms_path, privacy_path, join_path ].each do |path|
          visit path
          assert_selector "h1", count: 1
          assert_selector "#site_footer", count: 1
          within "#site_footer" do
            assert_link "Terms", href: terms_path
            assert_link "Privacy", href: privacy_path
            assert_link "Contact", href: "mailto:concourse@krishnan.ca"
          end
          evaluate_async_script("document.fonts.ready.then(() => arguments[0]())")
          assert_operator evaluate_script("document.documentElement.scrollWidth"), :<=, width
          FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
          page.save_screenshot(Rails.root.join("tmp/screenshots/public-#{path.delete_prefix('/')}-#{scheme}-#{width}.png"))
        end
      end
    end
  end

  test "footer links work signed out and clear the signed-in mobile tabs" do
    visit sign_in_path
    within("#site_footer") { click_link "Privacy" }
    assert_current_path privacy_path
    within("#site_footer") { click_link "Terms" }
    assert_current_path terms_path

    user = User.create!(ajent_sub: "footer-owner", handle: "reader", email: "reader@footer.test", organizations: [ Organization.default ])
    sign_in_as(subject: user.ajent_sub, email: user.email, name: "Reader")
    within("#site_footer") { click_link "Privacy" }
    assert_current_path privacy_path
    assert_selector "#tab_bar"
    execute_script "window.scrollTo(0, document.documentElement.scrollHeight)"
    geometry = evaluate_script(<<~JS)
      ({ footerBottom: document.querySelector('#site_footer nav').getBoundingClientRect().bottom,
         tabTop: document.querySelector('#tab_bar').getBoundingClientRect().top })
    JS
    assert_operator geometry["footerBottom"], :<, geometry["tabTop"]
    within("#site_footer") { click_link "Terms" }
    assert_current_path terms_path
  end
end
