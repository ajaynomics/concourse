require "application_system_test_case"

class BrowserNotificationsSystemTest < ApplicationSystemTestCase
  setup do
    @previous_vapid = Rails.application.config.x.vapid
    key = WebPush.generate_key
    Rails.application.config.x.vapid = { subject: "mailto:notifications@example.test", public_key: key.public_key, private_key: key.private_key }
    @user = User.create!(ajent_sub: "notifications-owner", handle: "notifications-owner", email: "notifications@example.test", name: "Notifications Owner", organizations: [ Organization.default ])
    sign_in_as(subject: @user.ajent_sub, email: @user.email, name: @user.name)
  end

  teardown { Rails.application.config.x.vapid = @previous_vapid }

  test "notifications stay off until a click and can be turned off again" do
    stub_push
    open_account
    assert_button alert_label(:on)
    assert_selector "[data-push-target=toggle][aria-pressed=false]"
    assert_equal 0, evaluate_script("window.permissionRequests")
    assert_equal 0, evaluate_script("window.subscribeCalls")
    assert_empty @user.push_subscriptions

    click_button alert_label(:on)
    assert_button alert_label(:off)
    assert_selector "[data-push-target=toggle][aria-pressed=true]"
    assert_equal 1, @user.push_subscriptions.count
    assert_equal true, evaluate_script("window.permissionHadGesture")
    reconnect_push
    assert_button alert_label(:off)
    assert_equal 1, evaluate_script("window.permissionRequests")

    click_button alert_label(:off)
    assert_button alert_label(:on)
    assert_selector "[data-push-target=toggle][aria-pressed=false]"
    assert_empty @user.push_subscriptions.reload
    assert_equal 1, evaluate_script("window.unsubscribeCalls")
    assert_equal 1, evaluate_script("window.permissionRequests")
    reconnect_push
    assert_selector "[data-push-target=toggle][aria-pressed=false]"
    assert_equal 1, evaluate_script("window.permissionRequests")
  end

  test "blocked permission explains browser settings without subscribing" do
    stub_push(permission: "denied")
    open_account
    click_button alert_label(:on)

    assert_selector "[data-push-target=status]", text: status_text(:blocked)
    assert_equal 0, evaluate_script("window.subscribeCalls")
    assert_empty @user.push_subscriptions
  end

  test "dismissing permission leaves alerts optional and off" do
    stub_push(permission: "default")
    open_account
    click_button alert_label(:on)

    assert_selector "[data-push-target=status]", text: status_text(:disabled)
    assert_selector "[data-push-target=toggle][aria-pressed=false]:not([disabled])"
    assert_equal 0, evaluate_script("window.subscribeCalls")
    assert_empty @user.push_subscriptions
  end

  test "unsupported browsers get an explanation and Home Screen guidance" do
    stub_push(unsupported: true)
    open_account

    assert_no_button alert_label(:on)
    assert_selector "[data-push-target=status]", text: status_text(:unsupported)
    assert_equal 0, evaluate_script("window.permissionRequests")
  end

  test "a missing installation key does not prompt for permission" do
    Rails.application.config.x.vapid = {}
    visit organization_root_path(Organization.default)
    open_account

    assert_no_button alert_label(:on)
    assert_selector "[data-push-target=status]", text: status_text(:unconfigured)
    assert_empty @user.push_subscriptions
  end

  test "a failed save rolls back the browser subscription and permits retry" do
    stub_push(fail_save: true)
    open_account
    click_button alert_label(:on)

    assert_selector "[data-push-target=status]", text: status_text(:failed)
    assert_selector "[data-push-target=toggle][aria-pressed=false]:not([disabled])"
    assert_equal 1, evaluate_script("window.unsubscribeCalls")
    assert_empty @user.push_subscriptions
    execute_script "window.failPushSave = false"
    click_button alert_label(:on)
    assert_button alert_label(:off)
    assert_equal 1, @user.push_subscriptions.count
  end

  test "a failed delete does not falsely report that notifications are off" do
    stub_push
    open_account
    click_button alert_label(:on)
    assert_button alert_label(:off)
    execute_script "window.failPushDelete = true"
    click_button alert_label(:off)

    assert_selector "[data-push-target=status]", text: status_text(:failed)
    assert_selector "[data-push-target=toggle][aria-pressed=true]:not([disabled])"
    assert_equal 1, @user.push_subscriptions.count
    assert_equal 0, evaluate_script("window.unsubscribeCalls")
  end

  test "an unavailable service worker fails without hanging the setting" do
    stub_push(unready: true)
    open_account
    assert_selector "[data-push-target=status]", text: status_text(:failed), wait: 5
    assert_button alert_label(:on), disabled: false
    assert_equal 0, evaluate_script("window.permissionRequests")
  end

  test "automatic page refresh keeps the notification setting usable" do
    stub_push
    open_account
    click_button alert_label(:on)
    assert_button alert_label(:off)

    evaluate_async_script <<~JS
      const done = arguments[0]
      document.addEventListener("turbo:morph", () => done(), { once: true })
      window.Turbo.renderStreamMessage('<turbo-stream action="refresh"></turbo-stream>')
    JS

    assert_selector "[data-push-target=toggle][aria-pressed=true]:not([disabled])"
    assert_equal 1, evaluate_script("window.permissionRequests")
    click_button alert_label(:off)
    assert_button alert_label(:on)
    assert_empty @user.push_subscriptions.reload
  end


  test "an expired sign-in cannot be mistaken for a successful opt-in" do
    stub_push
    open_account
    travel 13.hours
    click_button alert_label(:on)

    assert_selector "[data-push-target=status]", text: status_text(:failed)
    assert_selector "[data-push-target=toggle][aria-pressed=false]:not([disabled])"
    assert_equal 1, evaluate_script("window.unsubscribeCalls")
    assert_empty @user.push_subscriptions
  ensure
    travel_back
  end

  private

  def open_account
    find("#site_header details summary").click
  end

  def alert_label(state)
    I18n.t("layouts.application.alerts_#{state}")
  end

  def status_text(state)
    I18n.t("layouts.application.notifications.#{state}")
  end

  def reconnect_push
    evaluate_async_script <<~JS
      const done = arguments[0]
      window.Stimulus.getControllerForElementAndIdentifier(document.querySelector("[data-controller=push]"), "push").connect().then(() => done())
    JS
  end

  # Exercise the real Stimulus controller and Rails endpoint, without an OS
  # permission dialog or any traffic to a browser vendor's push service.
  def stub_push(permission: "granted", unsupported: false, fail_save: false, unready: false)
    result = evaluate_async_script <<~JS, permission, unsupported, fail_save, unready
      const [permission, unsupported, failSave, unready, done] = arguments
      Promise.all([import("controllers/application"), navigator.serviceWorker.ready]).then(async ([{ application }]) => {
        window.permissionRequests = window.subscribeCalls = window.unsubscribeCalls = 0
        window.failPushSave = failSave
        window.failPushDelete = false
        window.browserSubscription = null
        Object.defineProperty(window, "Notification", { configurable: true, value: {
          permission: "default",
          requestPermission: () => {
            window.permissionRequests++
            window.permissionHadGesture = navigator.userActivation.isActive
            Notification.permission = permission
            return Promise.resolve(permission)
          }
        } })
        if (unsupported) delete window.Notification
        const manager = {
          getSubscription: async () => window.browserSubscription,
          subscribe: async () => {
            window.subscribeCalls++
            const endpoint = "https://fcm.googleapis.com/fcm/send/system-browser"
            return window.browserSubscription = {
              endpoint,
              toJSON: () => ({ endpoint, keys: { p256dh: "p", auth: "a" } }),
              unsubscribe: async () => { window.unsubscribeCalls++; window.browserSubscription = null; return true }
            }
          }
        }
        Object.defineProperty(navigator.serviceWorker, "ready", { configurable: true,
          value: unready ? new Promise(() => {}) : Promise.resolve({ pushManager: manager }) })
        const fetch = window.fetch.bind(window)
        window.fetch = (url, options = {}) => {
          if (url === "/push_subscription" &&
              ((options.method === "POST" && window.failPushSave) ||
               (options.method === "DELETE" && window.failPushDelete))) {
            return Promise.resolve(new Response("", { status: 503 }))
          }
          return fetch(url, options)
        }
        const connected = application.getControllerForElementAndIdentifier(document.querySelector("[data-controller=push]"), "push").connect()
        if (!unready) await connected
        done("ready")
      }).catch(error => done(error.message))
    JS
    assert_equal "ready", result
  end
end
