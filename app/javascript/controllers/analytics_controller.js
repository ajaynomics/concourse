import { Controller } from "@hotwired/stimulus"

// Tells Rybbit who is driving: the user's handle, with their name, email,
// organization, and agents as traits. Every signed-out page clears that identity instead, so a shared
// browser never attributes a page to the last person who signed in on it.
//
// Rybbit installs window.rybbit itself, from a deferred cross-origin script
// that can run after this controller connects. A miss is retried on the
// script's load, because the call it would drop, clearUserId(), is the one
// that does not heal itself. A script that never loads leaves analytics
// silent, which is the correct failure.
export default class extends Controller {
  static values = { userId: String, traits: Object }

  connect() {
    if (window.rybbit) return this.tell()

    document
      .querySelector("script[data-site-id]")
      ?.addEventListener("load", () => this.element.isConnected && this.tell(), { once: true })
  }

  tell() {
    if (!window.rybbit) return

    if (this.userIdValue) {
      window.rybbit.identify(this.userIdValue, this.traitsValue)
    } else {
      window.rybbit.clearUserId()
    }
  }
}

// Custom events. Names are snake_case and properties never carry content.
export function trackEvent(name, properties = {}) {
  try {
    window.rybbit?.event(name, properties)
    window.ahoy?.track(name, properties)
  } catch {
    // Analytics must never be the reason a click stops working.
  }
}
