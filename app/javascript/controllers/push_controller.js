import { Controller } from "@hotwired/stimulus"
import { trackEvent } from "controllers/analytics_controller"

// Opt-in for this browser only. Loading or installing the app never requests
// permission or creates a Web Push subscription (RFC 8030).
export default class extends Controller {
  static values = { key: String, url: String, on: String, off: String, endpoint: String, messages: Object }
  static targets = ["toggle", "label", "status"]

  async connect() {
    this.subscription = null
    this.busy = true
    this.toggleTarget.hidden = true
    this.toggleTarget.disabled = true
    try {
      if (!this.keyValue) return this.render(null, this.messagesValue.unconfigured)
      if (!this.supported) return this.render(null, this.messagesValue.unsupported)

      this.toggleTarget.hidden = false
      // A browser subscription left from another sign-in must not opt this
      // person in. The server already removed it when that session ended.
      let existing = await this.current()
      if (existing && existing.endpoint !== this.endpointValue) {
        await existing.unsubscribe()
        existing = null
      }
      this.render(existing)
    } catch {
      this.render(null, this.messagesValue.failed)
    } finally {
      this.busy = false
      this.toggleTarget.disabled = false
    }
  }

  // The server ends this session's alerts even when browser cleanup fails.
  async forget(event) {
    if (!this.supported) return

    event.preventDefault()
    const form = event.target
    try {
      const existing = await this.current()
      if (existing) {
        await this.send("DELETE", { endpoint: existing.endpoint })
        await existing.unsubscribe()
      }
    } catch {
      // Sign-out must still reach the server if the worker or network is down.
    } finally {
      form.submit()
    }
  }

  get supported() {
    return window.isSecureContext && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
  }

  async toggle() {
    if (this.busy || !this.keyValue || !this.supported) return

    this.busy = true
    this.toggleTarget.disabled = true
    let created = null
    try {
      if (this.subscription) {
        const response = await this.send("DELETE", { endpoint: this.subscription.endpoint })
        if (!response.ok) throw new Error("Notification setting was not saved")
        await this.subscription.unsubscribe()
        this.endpointValue = ""
        this.render(null)
        trackEvent("alerts_turned_off")
      } else {
        // Request before the first await on this path: browsers require the
        // user's click, not a continuation after waiting for a service worker.
        const permission = await Notification.requestPermission()
        if (permission !== "granted") return this.render(null)

        const registration = await this.worker()
        created = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: decode(this.keyValue)
        })
        const response = await this.send("POST", created.toJSON())
        if (!response.ok) throw new Error("Notification setting was not saved")
        this.endpointValue = created.endpoint
        this.render(created)
        created = null
        trackEvent("alerts_turned_on")
      }
    } catch {
      if (created) {
        try { await created.unsubscribe() } catch { /* Already unavailable. */ }
      }
      this.render(this.subscription, this.messagesValue.failed)
    } finally {
      this.busy = false
      this.toggleTarget.disabled = false
    }
  }

  // ready never settles after a failed registration. Neither this setting nor
  // sign-out should hang indefinitely waiting for it.
  async worker() {
    let timer
    try {
      const registration = await Promise.race([
        navigator.serviceWorker.ready,
        new Promise((resolve) => { timer = setTimeout(resolve, 2000, null) })
      ])
      if (!registration) throw new Error("Service worker unavailable")
      return registration
    } finally {
      clearTimeout(timer)
    }
  }

  async current() {
    return (await this.worker()).pushManager.getSubscription()
  }

  send(method, body) {
    return fetch(this.urlValue, {
      method,
      credentials: "same-origin",
      redirect: "error",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
      },
      body: JSON.stringify(body)
    })
  }

  render(subscription, message) {
    this.subscription = subscription
    this.labelTarget.textContent = subscription ? this.offValue : this.onValue
    this.toggleTarget.setAttribute("aria-pressed", subscription ? "true" : "false")
    this.statusTarget.textContent = message || (subscription ? this.messagesValue.enabled :
      Notification.permission === "denied" ? this.messagesValue.blocked : this.messagesValue.disabled)
  }
}

// The VAPID public key arrives base64url-encoded.
function decode(key) {
  const padded = (key + "=".repeat((4 - (key.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/")
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0))
}
