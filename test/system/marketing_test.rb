require "application_system_test_case"

class MarketingPagesTest < ApplicationSystemTestCase
  setup do
    @release = Rails.application.config.x.concourse.release_line
    Rails.application.config.x.concourse.release_line = 3
  end

  teardown do
    Rails.application.config.x.concourse.release_line = @release
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    page.driver.browser.manage.window.resize_to(390, 844)
  end

  test "the landing is readable at narrow, mobile, tablet and desktop widths" do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
      { name: "prefers-reduced-motion", value: "reduce" }
    ])
    [ 320, 390, 768, 1440 ].each do |width|
      page.driver.browser.manage.window.resize_to(width, 1000)
      visit sign_in_path
      assert_selector "h1", text: "Stop being"
      assert_selector "button[aria-label='Play connection film']"
      evaluate_async_script("document.fonts.ready.then(() => arguments[0]())")
      assert_operator evaluate_script("document.documentElement.scrollWidth"), :<=, width
      assert evaluate_script("(() => { const text = document.createRange(); text.selectNodeContents(document.querySelector('h1')); return [...text.getClientRects()].every(rect => rect.left >= 0 && rect.right <= document.documentElement.clientWidth); })()"), "Hero text must fit even when decorative overflow is clipped"
      assert evaluate_script("document.querySelector('video').paused")
      assert_no_selector "video source[src]", visible: :all
      assert_equal "rgb(24, 26, 23)", evaluate_script("getComputedStyle(document.body).backgroundColor")
      FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
      page.save_screenshot(Rails.root.join("tmp/screenshots/marketing-#{width}.png"))
    end
    find(".m-faq summary", text: "Is this an agent orchestrator?").click
    assert_selector ".m-faq details[open]", text: "No. Your agents choose whom to contact"
    first(:link, "Connect with Pi").click
    assert_current_path join_path
    assert_selector "h1", text: "Connect your agents"
    assert_text "You sign in and approve access in your browser."
    assert_no_selector "body.concourse-marketing"
  end

  test "motion has explicit controls and pauses offscreen" do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
      { name: "prefers-reduced-motion", value: "no-preference" }
    ])
    page.driver.browser.manage.window.resize_to(1440, 1000)
    visit sign_in_path
    assert_selector "button[aria-label='Pause connection film']", wait: 15
    assert_selector "video source[src]", count: 2, visible: :all
    find("button[aria-label='Pause connection film']").click
    assert_selector "button[aria-label='Play connection film']"
    assert evaluate_script("document.querySelector('video').paused")
    find("button[aria-label='Play connection film']").click
    assert_selector "button[aria-label='Pause connection film']"
    execute_script "document.querySelector('#networks').scrollIntoView()"
    assert_selector "button[aria-label='Play connection film']", visible: :all
    assert evaluate_script("document.querySelector('video').paused")
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
      { name: "prefers-reduced-motion", value: "reduce" }
    ])
    execute_script "window.scrollTo(0, 0)"
    assert_selector "button[aria-label='Play connection film']"
  end

  test "a failed encoding falls back without losing the film" do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
      { name: "prefers-reduced-motion", value: "reduce" }
    ])
    page.driver.browser.manage.window.resize_to(1440, 1000)
    visit sign_in_path
    assert_selector "button[aria-label='Play connection film']"
    execute_script "document.querySelector('video source').dataset.src = '/assets/missing-film.webm'"
    find("button[aria-label='Play connection film']").click
    assert_selector "button[aria-label='Pause connection film']", wait: 15
    assert evaluate_script("document.querySelector('video').currentSrc.includes('.mp4')")
  end

  test "exhausted film sources keep the poster without a false playback control" do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
      { name: "prefers-reduced-motion", value: "reduce" }
    ])
    page.driver.browser.manage.window.resize_to(1440, 1000)
    visit sign_in_path
    assert_selector "button[aria-label='Play connection film']"
    execute_script "document.querySelectorAll('video source').forEach((source, i) => source.dataset.src = `/assets/missing-film-${i}.mp4`)"
    find("button[aria-label='Play connection film']").click
    assert_no_selector ".m-film-control", wait: 15
    assert_selector "video[poster]"
    assert evaluate_script("document.querySelector('video').paused")
    assert_text "they write to each other, and you go back to work."
  end

  test "manual play does not load an offscreen film while its caption is visible" do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [
      { name: "prefers-reduced-motion", value: "reduce" }
    ])
    page.driver.browser.manage.window.resize_to(1440, 1000)
    visit sign_in_path
    assert_selector "button[aria-label='Play connection film']"
    execute_script "window.scrollTo(0, Math.ceil(scrollY + document.querySelector('video').getBoundingClientRect().bottom) + 4)"
    evaluate_async_script("requestAnimationFrame(() => requestAnimationFrame(() => arguments[0]()))")
    assert_operator evaluate_script("document.querySelector('video').getBoundingClientRect().bottom"), :<=, 0
    find("button[aria-label='Play connection film']").click
    evaluate_async_script("requestAnimationFrame(() => requestAnimationFrame(() => arguments[0]()))")
    assert evaluate_script("document.querySelector('video').paused")
    assert_no_selector "video source[src]", visible: :all
  end
end
