require "application_system_test_case"

class UiVisualTest < ApplicationSystemTestCase
  VIEWPORTS = { phone: [ 390, 844 ], desktop: [ 1280, 900 ] }.freeze

  setup do
    @organization = Organization.create!(name: "Northstar Engineering", email_domains: "northstar.test")
    @owner = User.create!(ajent_sub: "ui-owner", handle: "kim", email: "kim@northstar.test", name: "Kim", organizations: [ @organization ])
    @teammate = User.create!(ajent_sub: "ui-peer", handle: "sam", email: "sam@northstar.test", name: "Sam", organizations: [ @organization ])
    @mine = Agent.create!(owner: @owner, organization: @organization, handle: "reviewer", oauth_client_id: "ui-reviewer", description: "Reviews migrations and deployment plans.")
    @peer = Agent.create!(owner: @teammate, organization: @organization, handle: "release-agent", oauth_client_id: "ui-release", description: "Prepares release notes and checks the rollout.")
    @organization.projects.create!(name: "Platform", agents: [ @mine, @peer ])
    @waiting = Task.open!(recipient: @peer, caller: @mine)
    Message.record!(task: @waiting, role: "ROLE_USER", sender: @mine, parts: [ { "text" => "Review the rolling deployment plan" } ])
    question = Message.record!(task: @waiting, role: "ROLE_AGENT", sender: @peer,
      parts: [ { "text" => "Should we keep the old column for one more deploy?\n\nPlan: https://example.test/" + "release-checklist/" * 12 } ])
    @waiting.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @peer, status_message: question)
    @working = Task.open!(recipient: @peer, caller: @mine)
    Message.record!(task: @working, role: "ROLE_USER", sender: @mine, parts: [ { "text" => "Prepare the release notes" } ])
    @working.transition_to!("TASK_STATE_WORKING", by: @peer)
    @done = Task.open!(recipient: @peer, caller: @mine)
    Message.record!(task: @done, role: "ROLE_USER", sender: @mine, parts: [ { "text" => "Check the staging rollout" } ])
    @done.transition_to!("TASK_STATE_COMPLETED", by: @peer)
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    page.driver.browser.manage.window.resize_to(390, 844)
  end

  %w[light dark].each do |scheme|
    VIEWPORTS.each do |size, dimensions|
      test "#{scheme} #{size} pages retain hierarchy, contrast and keyboard access" do
        page.driver.browser.manage.window.resize_to(*dimensions)
        page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
          { name: "prefers-color-scheme", value: scheme },
          { name: "prefers-reduced-motion", value: "reduce" }
        ])

        visit sign_in_path
        assert_rendered_page("sign-in", scheme, size)
        assert_contrast(".btn-primary", minimum: 4.5)
        page.driver.browser.action.send_keys(:tab).perform
        assert_selector ".skip-link", visible: true
        assert_operator find(".skip-link").native.rect.height, :>=, 44
        assert_operator find(".skip-link").native.rect.width, :>=, 44
        assert_equal "auto", evaluate_script("getComputedStyle(document.querySelector('.skip-link')).clip")
        assert_operator evaluate_script("parseFloat(getComputedStyle(document.activeElement).outlineWidth)"), :>=, 2
        page.driver.browser.action.send_keys(:enter).perform
        assert_equal "main", evaluate_script("document.activeElement.id")

        sign_in_as(subject: "ui-owner", email: "kim@northstar.test", name: "Kim")
        assert_selector "#organization_context", text: @organization.name
        navigation = size == :phone ? "#tab_bar" : "#site_header nav"
        assert_selector "#{navigation} a[href='#{projects_path(@organization)}']"
        assert_rendered_page("board", scheme, size)
        assert_task_signal
        active = find("#{navigation} [aria-current='page']")
        assert_operator active.native.rect.height, :>=, 44
        if size == :phone
          assert_operator evaluate_script("parseFloat(getComputedStyle(document.querySelector('#tab_bar [aria-current=page]'), '::before').height)"), :>=, 2
        end

        visit agents_path(@organization)
        assert_rendered_page("directory", scheme, size)
        search = find("input[type=search]")
        search.send_keys(:tab)
        search.click
        assert_contrast("input[type=search]", minimum: 4.5)
        assert_operator evaluate_script("parseFloat(getComputedStyle(document.querySelector('input[type=search]')).outlineWidth)"), :>=, 2
        assert_operator evaluate_script("parseFloat(getComputedStyle(document.querySelector('input[type=search]')).fontSize)"), :>=, 16
        find("input[type=search]").fill_in with: "rollout"
        assert_no_selector "a[href='#{agent_path(@organization, @owner.handle, @mine.handle)}']"
        assert_selector "a[href='#{agent_path(@organization, @teammate.handle, @peer.handle)}']"

        visit my_task_path(@organization, @waiting)
        assert_selector "#respond textarea"
        assert_rendered_page("task", scheme, size)
        assert_contrast("#respond .btn-primary", minimum: 4.5)
        field = find("#respond textarea")
        field.click
        assert_operator evaluate_script("parseFloat(getComputedStyle(document.activeElement).outlineWidth)"), :>=, 2
        assert_operator evaluate_script("parseFloat(getComputedStyle(document.querySelector('.composer')).borderTopWidth)"), :>=, 2
        assert_equal "vertical", evaluate_script("getComputedStyle(document.querySelector('#respond textarea')).resize")

        if size == :desktop
          assert_selector "turbo-cable-stream-source[connected]", visible: :all
          assert_selector ".live-on"
          execute_script "document.querySelectorAll('turbo-cable-stream-source').forEach(el => el.removeAttribute('connected'))"
          assert_no_selector ".live-on"
          assert_selector ".live-off", wait: 5
        end
      end
    end
  end

  test "a signed-in person without an organization never sees a live claim" do
    sign_in_as(subject: "ui-no-org", email: "visitor@unaffiliated.test", name: "Visitor")
    assert_selector "#site_header"
    assert_no_selector "turbo-cable-stream-source", visible: :all
    assert_no_selector ".live", visible: :all
    assert_no_selector "#tab_bar", visible: :all
  end

  test "save feedback clears the header at phone and desktop sizes" do
    sign_in_as(subject: "ui-owner", email: "kim@northstar.test", name: "Kim")
    VIEWPORTS.each do |size, dimensions|
      page.driver.browser.manage.window.resize_to(*dimensions)
      visit edit_agent_path(@organization, @owner.handle, @mine.handle)
      fill_in "Display name (optional)", with: "Release reviewer"
      # Hold only the saved toast for geometry, not its five-second dismissal timing.
      execute_script <<~JS
        document.addEventListener('turbo:before-render', function holdSaveFeedback(event) {
          const notice = event.detail.newBody.querySelector('#notice')
          if (!notice?.textContent.includes('Card saved.')) return
          notice.dataset.flashDismissAfterValue = '0'
          document.removeEventListener('turbo:before-render', holdSaveFeedback)
        })
      JS
      click_button "Save card"
      assert_selector "#notice[data-flash-dismiss-after-value='0']", text: "Card saved."
      geometry = evaluate_script(<<~JS)
        ({ headerBottom: document.querySelector('#site_header').getBoundingClientRect().bottom,
           flashTop: document.querySelector('#flash').getBoundingClientRect().top })
      JS
      assert_operator geometry["flashTop"], :>, geometry["headerBottom"]
      page.save_screenshot(Rails.root.join("tmp/screenshots/ui-flash-#{size}.png"))
    end
  end


  private

  def assert_rendered_page(name, scheme, size)
    evaluate_async_script("document.fonts.ready.then(() => arguments[0]())")
    assert_equal scheme == "dark", evaluate_script("matchMedia('(prefers-color-scheme: dark)').matches")
    expected_background = scheme == "dark" ? "rgb(11, 17, 32)" : "rgb(246, 242, 239)"
    assert_equal expected_background, evaluate_script("getComputedStyle(document.body).backgroundColor")
    assert_contrast("main", minimum: 4.5)
    assert_contrast(".page-lead", minimum: 4.5) if page.has_css?(".page-lead")
    assert_operator evaluate_script("document.documentElement.scrollWidth"), :<=,
      evaluate_script("document.documentElement.clientWidth"), "#{name} scrolls horizontally"
    assert_operator evaluate_script("parseFloat(getComputedStyle(document.querySelector('.btn-primary, .row, main')).animationDuration)"), :<=, 0.001

    if size == :phone && page.has_css?("#tab_bar")
      covered = evaluate_script(<<~JS)
        (() => {
          window.scrollTo(0, document.documentElement.scrollHeight)
          const main = document.querySelector('main')
          const bottoms = [...main.querySelectorAll('a, button, textarea, input:not([type=hidden])')]
            .filter(el => el.checkVisibility({ visibilityProperty: true }))
            .map(el => el.getBoundingClientRect().bottom)
          return Math.max(0, ...bottoms) > document.querySelector('#tab_bar').getBoundingClientRect().top + 1
        })()
      JS
      assert_not covered, "#{name} ends under the mobile navigation"
      execute_script "window.scrollTo(0, 0)"
    end

    directory = Rails.root.join("tmp/screenshots")
    FileUtils.mkdir_p(directory)
    page.save_screenshot(directory.join("ui-#{name}-#{scheme}-#{size}.png"))
  end

  def assert_task_signal
    assert_selector ".state[data-move][data-state='TASK_STATE_INPUT_REQUIRED']"
    assert_no_selector ".state[data-move][data-state='TASK_STATE_WORKING']"
    assert_no_selector ".state[data-move][data-state='TASK_STATE_COMPLETED']"
    colors = evaluate_script(<<~JS)
      (() => {
        const move = document.querySelector('.state[data-move]')
        const working = document.querySelector('.state[data-state=TASK_STATE_WORKING]')
        const ball = document.querySelector('.lifeline[data-move] .lifeline-ball')
        return { move: getComputedStyle(move).color, working: getComputedStyle(working).color,
          ball: getComputedStyle(ball).fill }
      })()
    JS
    assert_not_equal colors["working"], colors["move"]
    assert_equal "rgb(53, 156, 244)", colors["ball"]
    assert_contrast(".state[data-move]", minimum: 4.5)
  end

  def assert_contrast(selector, minimum:)
    ratio = evaluate_script(<<~JS, selector)
      (() => {
        const el = document.querySelector(arguments[0])
        const style = getComputedStyle(el)
        const luminance = color => {
          const rgb = color.match(/[0-9.]+/g).slice(0, 3).map(Number).map(n => {
            const value = n / 255
            return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
          })
          return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        }
        let background = el
        while (getComputedStyle(background).backgroundColor === 'rgba(0, 0, 0, 0)' && background.parentElement) {
          background = background.parentElement
        }
        const values = [luminance(style.color), luminance(getComputedStyle(background).backgroundColor)]
        return (Math.max(...values) + 0.05) / (Math.min(...values) + 0.05)
      })()
    JS
    assert_operator ratio, :>=, minimum, "#{selector} has insufficient rendered contrast"
  end
end
