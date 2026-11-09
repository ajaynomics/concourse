require "application_system_test_case"

# The pages are designed for a phone first. Every page a person can reach is
# checked at the phone size the system tests run at: nothing scrolls
# sideways, every control is big enough to tap, no text field is small
# enough for iOS to zoom into on focus, and the tab bar covers nothing at
# the end of the page.
class MobileLayoutTest < ApplicationSystemTestCase
  # WCAG 2.2 target size (2.5.8), the minimum; the pages aim for 44.
  MINIMUM_TARGET = 24
  # Safari zooms into a focused field whose text is smaller than this.
  MINIMUM_FIELD_TEXT = 16

  setup do
    @ajay = User.create!(ajent_sub: "42", handle: "ajay", email: "ajay@example.com", name: "Ajay", organizations: [ Organization.default ])
    Organization.default.memberships.find_by!(user: @ajay).update!(role: "owner")
    @riley = User.create!(ajent_sub: "7", handle: "riley", email: "riley@example.com", name: "Riley", organizations: [ Organization.default ])
    @codex = Agent.create!(owner: @ajay, handle: "codex", oauth_client_id: "client-a", description: "Reviews pull requests in the travel booking monorepo.")
    @pi = Agent.create!(owner: @riley, handle: "flights-search-orchestrator", oauth_client_id: "client-b", description: "Flights search.")
    @task = Task.open!(recipient: @pi, caller: @codex)
    Message.record!(task: @task, role: "ROLE_USER", sender: @codex,
      parts: [ { "text" => "Which fare rules apply to https://example.com/a/very/long/link/that/does/not/break/on/its/own/0123456789abcdef?" } ])
    asked = Message.record!(task: @task, role: "ROLE_AGENT", sender: @pi, parts: [ { "text" => "Which route?" } ])
    @task.transition_to!("TASK_STATE_INPUT_REQUIRED", by: @pi, status_message: asked)
    Artifact.record!(task: @task, by: @pi, name: "fares.json", parts: [ { "data" => { "routes" => [ "YYZ-LHR" ] * 20 } } ])
    %w[Flights Hotels Auto\ trips Corporate\ travel\ policy].each { |name| Organization.default.projects.create!(name: name, agents: [ @pi ]) }
    @codex.update!(projects: Organization.default.projects.where(slug: "flights"))
  end

  test "every page fits a phone" do
    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")
    organization = Organization.default

    [
      organization_root_path(organization),
      agents_path(organization),
      agents_path(organization, project: "flights"),
      projects_path(organization),
      new_project_path(organization),
      edit_project_path(organization, "flights"),
      agent_path(organization, "riley", "flights-search-orchestrator"),
      edit_agent_path(organization, "ajay", "codex"),
      my_tasks_path(organization),
      my_task_path(organization, @task),
      edit_organization_path(organization),
      join_path,
      terms_path,
      privacy_path
    ].each do |path|
      visit path
      assert_selector "#tab_bar"
      assert_fits_a_phone(path)
    end
  end

  test "signed-out pages fit a phone" do
    [ sign_in_path, join_path, terms_path, privacy_path ].each do |path|
      visit path
      assert_fits_a_phone(path)
    end
  end

  test "the tab bar is for phones and the header navigation for wider screens" do
    sign_in_as(subject: "42", email: "ajay@example.com", name: "Ajay")
    assert_selector "#tab_bar"
    assert_no_selector "nav[aria-label='Primary']:not(#tab_bar)"

    page.driver.browser.manage.window.resize_to(1280, 900)
    assert_no_selector "#tab_bar"
    assert_selector "#site_header nav[aria-label='Primary']"
  ensure
    page.driver.browser.manage.window.resize_to(390, 844)
  end

  private

  def assert_fits_a_phone(path)
    # Widths change when the web font replaces the fallback.
    evaluate_async_script("document.fonts.ready.then(() => arguments[0]())")
    layout = evaluate_script(<<~JS)
      (() => {
        // A skip link is visually hidden until it has focus.
        const visible = el => {
          if (el.matches(".sr-only:not(:focus), .skip-link:not(:focus)")) return false
          const box = el.getBoundingClientRect()
          const style = getComputedStyle(el)
          return box.width > 0 && box.height > 0 && style.visibility != "hidden"
        }
        const describe = el => `${el.tagName.toLowerCase()}${el.id ? "#" + el.id : ""} "${(el.innerText || el.value || el.getAttribute("aria-label") || "").trim().slice(0, 40)}"`
        const box = el => el.getBoundingClientRect()

        const width = document.documentElement.clientWidth
        // The outermost element past the right edge that no ancestor clips.
        const clipped = el => { for (let a = el.parentElement; a; a = a.parentElement) if (getComputedStyle(a).overflowX != "visible") return true; return false }
        const past = el => box(el).right > width + 1
        const overflowing = [...document.querySelectorAll("body *")].filter(visible)
          .filter(el => past(el) && !past(el.parentElement) && !clipped(el))
          .map(describe)

        // Inline links in running text are exempt from target size (2.5.8).
        const inProse = el => el.tagName == "A" && getComputedStyle(el).display == "inline" && el.closest("p, li, dd")
        const small = [...document.querySelectorAll("a[href], button, summary, select, input:not([type=hidden]), textarea")]
          .filter(visible).filter(el => !inProse(el))
          .filter(el => box(el).height < #{MINIMUM_TARGET} || box(el).width < #{MINIMUM_TARGET})
          .map(el => `${describe(el)} ${Math.round(box(el).width)}x${Math.round(box(el).height)}`)

        const zooming = [...document.querySelectorAll("select, input:not([type=hidden]):not([type=checkbox]):not([type=radio]), textarea")]
          .filter(visible).filter(el => parseFloat(getComputedStyle(el).fontSize) < #{MINIMUM_FIELD_TEXT})
          .map(el => `${describe(el)} ${getComputedStyle(el).fontSize}`)

        window.scrollTo(0, document.documentElement.scrollHeight)
        const tabBar = document.getElementById("tab_bar")
        const main = document.getElementById("main")
        const last = [...main.querySelectorAll("*")].filter(visible).map(box).reduce((bottom, b) => Math.max(bottom, b.bottom), 0)
        const covered = tabBar && last > box(tabBar).top + 1

        return { scrollWidth: document.documentElement.scrollWidth, width, overflowing, small, zooming, covered }
      })()
    JS

    assert_operator layout["scrollWidth"], :<=, layout["width"], "#{path} scrolls sideways: #{layout["overflowing"].first(5).join(", ")}"
    assert_empty layout["small"], "#{path} has controls smaller than #{MINIMUM_TARGET}px"
    assert_empty layout["zooming"], "#{path} has fields iOS zooms into"
    assert_not layout["covered"], "#{path} ends under the tab bar"
  end
end
