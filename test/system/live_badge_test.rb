require "application_system_test_case"

# The header's Live badge follows the page's Action Cable subscription. Each
# visit subscribes afresh, so for one round trip the page is not connected;
# that gap must never show as Offline. Keeping the element permanent does not
# avoid it: moving a custom element still disconnects it (hotwired/turbo#868).
class LiveBadgeTest < ApplicationSystemTestCase
  setup do
    @organization = Organization.create!(name: "Acme")
    User.create!(ajent_sub: "1", handle: "kim", email: "kim@example.com", name: "Kim", organizations: [ @organization ])
    page.driver.browser.manage.window.resize_to(1280, 900)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(390, 844)
  end

  test "changing pages never flashes Offline, and a lost connection does show it" do
    sign_in_as(subject: "1", email: "kim@example.com", name: "Kim")
    assert_selector "turbo-cable-stream-source[connected]", visible: :all
    assert_selector ".live-on", text: "Live"

    # The window outlives Turbo's body swaps, so this sees every frame.
    execute_script <<~JS
      window.offlineSeen = false
      const watch = () => {
        const off = document.querySelector(".live-off")
        if (off && off.checkVisibility({ visibilityProperty: true })) window.offlineSeen = true
        requestAnimationFrame(watch)
      }
      requestAnimationFrame(watch)
    JS

    [ [ "Agents", agents_path(@organization) ], [ "Tasks", my_tasks_path(@organization) ],
      [ "Board", organization_root_path(@organization) ], [ "Agents", agents_path(@organization) ] ].each do |label, path|
      finishing_turbo_visit_to(path) { within("#site_header") { click_link label } }
      assert_selector "turbo-cable-stream-source[connected]", visible: :all
    end
    assert_equal false, evaluate_script("window.offlineSeen")

    # What turbo-rails does when the subscription drops.
    execute_script "document.querySelectorAll('turbo-cable-stream-source').forEach(source => source.removeAttribute('connected'))"
    assert_selector ".live-off", text: "Offline", wait: 5
    assert_no_selector ".live-on", text: "Live"
  end
end
