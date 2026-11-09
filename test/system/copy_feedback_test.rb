require "application_system_test_case"

class CopyFeedbackTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(ajent_sub: "copy-owner", handle: "copy-owner", email: "copy@example.com", name: "Copy Owner", organizations: [ Organization.default ])
    @agent = Agent.create!(owner: @owner, handle: "reviewer", oauth_client_id: "copy-client")
    sign_in_as(subject: @owner.ajent_sub, email: @owner.email, name: @owner.name)
  end

  test "an endpoint copy failure explains how to recover and a retry succeeds" do
    visit agent_path(Organization.default, @owner.handle, @agent.handle)
    stub_clipboard(fail: true)
    within "[data-controller='clipboard']" do
      click_button I18n.t("agents.show.copy")
      assert_selector "[role='status']", text: I18n.t("agents.show.copy_failed")
    end

    stub_clipboard(fail: false)
    within "[data-controller='clipboard']" do
      click_button I18n.t("agents.show.copy")
      assert_text I18n.t("agents.show.copied")
      assert_no_text I18n.t("agents.show.copy_failed")
    end
    assert_equal A2a::Card.endpoint_url(@agent), evaluate_script("window.copiedText")
  end

  test "guide copy controls leave code readable and copy only code" do
    visit join_path
    assert_selector "pre [data-code-copy-button]"
    stub_clipboard(fail: true)
    within first("pre") do
      click_button I18n.t("joins.show.copy")
      assert_selector "[role='status']", text: I18n.t("joins.show.copy_failed")
    end

    stub_clipboard(fail: false)
    expected = evaluate_script("document.querySelector('pre code').innerText")
    within first("pre") do
      click_button I18n.t("joins.show.copy")
      assert_selector "[role='status']", text: I18n.t("joins.show.copied")
    end
    assert_equal expected, evaluate_script("window.copiedText")
    geometry = evaluate_script(<<~JS)
      (() => {
        const pre = document.querySelector("pre")
        const button = pre.querySelector("button").getBoundingClientRect()
        const code = pre.querySelector("code").getBoundingClientRect()
        return { buttonBottom: button.bottom, codeTop: code.top }
      })()
    JS
    assert_operator geometry["buttonBottom"], :<=, geometry["codeTop"]
  end

  test "Escape returns account menu focus to its trigger" do
    summary = find("#site_header details summary")
    summary.click
    menu_link = find("#site_header details a", match: :first)
    menu_link.send_keys(:tab)
    page.send_keys(:escape)
    assert_no_selector "#site_header details[open]"
    assert_equal "SUMMARY", evaluate_script("document.activeElement.tagName")
  end

  test "a rejected retry clears the previous endpoint success" do
    visit agent_path(Organization.default, @owner.handle, @agent.handle)
    stub_clipboard(fail: false)
    within "[data-controller='clipboard']" do
      click_button I18n.t("agents.show.copy")
      assert_text I18n.t("agents.show.copied")
    end
    stub_clipboard(fail: true)
    within "[data-controller='clipboard']" do
      click_button I18n.t("agents.show.copied")
      assert_selector "[role='status']", text: I18n.t("agents.show.copy_failed")
      assert_no_text I18n.t("agents.show.copied")
      assert_button I18n.t("agents.show.copy")
    end
  end

  test "guide code can still be copied after a Turbo cached Back visit" do
    visit join_path
    assert_selector "pre [data-code-copy-button]"
    within "#tab_bar" do
      click_link I18n.t("nav.agents")
    end
    assert_current_path agents_path(Organization.default)
    go_back
    assert_current_path join_path
    assert_selector "pre [data-code-copy-button]"
    # Cached content appears before Turbo finishes replacing the page.
    assert_no_selector "html[aria-busy='true']"
    stub_clipboard(fail: false)
    expected = evaluate_script("document.querySelector('pre code').innerText")
    within first("pre") do
      click_button I18n.t("joins.show.copy")
      assert_selector "[role='status']", text: I18n.t("joins.show.copied")
    end
    assert_equal expected, evaluate_script("window.copiedText")
  end


  private

  def stub_clipboard(fail:)
    execute_script <<~JS, fail
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: text => {
          if (arguments[0]) return Promise.reject(new Error("Clipboard denied"))
          window.copiedText = text
          return Promise.resolve()
        } }
      })
    JS
  end
end
