require "application_system_test_case"

class PwaSystemTest < ApplicationSystemTestCase
  test "the browser discovers the manifest and activates the root-scoped worker" do
    visit join_path
    data = evaluate_async_script <<~JS
      const done = arguments[0]
      ;(async () => {
        const registration = await navigator.serviceWorker.ready
        const manifest = await fetch(document.querySelector('link[rel="manifest"]').href).then(response => response.json())
        const cached = []
        for (const name of await caches.keys()) {
          for (const request of await (await caches.open(name)).keys()) cached.push(new URL(request.url).pathname)
        }
        done({ scope: new URL(registration.scope).pathname, worker: new URL(registration.active.scriptURL).pathname, manifest, cached })
      })()
    JS

    assert_equal "/", data["scope"]
    assert_equal "/service-worker.js", data["worker"]
    assert_equal "Concourse", data["manifest"]["name"]
    assert_equal "/", data["manifest"]["id"]
    assert_equal "/", data["manifest"]["start_url"]
    assert_equal "standalone", data["manifest"]["display"]
    assert_equal [ "/offline.html" ], data["cached"]
  end

  test "the optional install prompt survives live refresh and opens only on a click" do
    owner = User.create!(ajent_sub: "pwa-owner", handle: "pwa-owner", email: "pwa@example.test", name: "PWA Owner", organizations: [ Organization.default ])
    sign_in_as(subject: owner.ajent_sub, email: owner.email, name: owner.name)
    evaluate_async_script <<~JS
      const done = arguments[0]
      import("controllers/pwa_install_controller").then(() => {
        window.installPrompts = 0
        const event = new Event("beforeinstallprompt", { cancelable: true })
        event.prompt = () => { window.installPrompts++; window.installHadGesture = navigator.userActivation.isActive }
        event.userChoice = Promise.resolve({ outcome: "dismissed" })
        window.dispatchEvent(event)
        done()
      })
    JS
    find("#site_header details summary").click
    assert_button I18n.t("layouts.application.install")
    assert_equal 0, evaluate_script("window.installPrompts")

    evaluate_async_script <<~JS
      const done = arguments[0]
      document.addEventListener("turbo:morph", () => done(), { once: true })
      window.Turbo.renderStreamMessage('<turbo-stream action="refresh"></turbo-stream>')
    JS

    assert_button I18n.t("layouts.application.install")
    click_button I18n.t("layouts.application.install")
    assert_equal 1, evaluate_script("window.installPrompts")
    assert_equal true, evaluate_script("window.installHadGesture")
    assert_no_button I18n.t("layouts.application.install")
  end


  test "a failed navigation fetch returns only the cached offline page" do
    visit join_path
    evaluate_async_script "navigator.serviceWorker.ready.then(() => arguments[0]())"

    # Chromium's page-only offline emulation leaves service-worker requests
    # online. Exercise the real handler with a rejected fetch and real cache,
    # rather than claim that emulation proves a device-wide network outage.
    result = evaluate_async_script <<~JS
      const done = arguments[0]
      const handlers = {}
      const attempted = [], matched = []
      const self = { addEventListener: (name, handler) => { handlers[name] = handler } }
      const fetch = request => { attempted.push(request.url); return Promise.reject(new TypeError("Synthetic network loss")) }
      const caches = { match: path => { matched.push(path); return window.caches.match(path) } }
      #{Rails.root.join("app/views/pwa/service-worker.js").read}
      let response
      handlers.fetch({ request: { mode: "navigate", url: location.origin + "/private-task" }, respondWith: value => { response = value } })
      response.then(value => value.text()).then(html => done({ attempted, matched, html })).catch(error => done({ error: error.message }))
    JS

    assert_nil result["error"]
    assert_equal [ URI.join(page.current_url, "/private-task").to_s ], result["attempted"]
    assert_equal [ "/offline.html" ], result["matched"]
    assert_equal Rails.public_path.join("offline.html").read, result["html"]
    assert_equal "You're offline", Nokogiri::HTML(result["html"]).at("h1").text
  end
end
