import { Controller } from "@hotwired/stimulus"
import { trackEvent } from "controllers/analytics_controller"

// Chromium offers installation through beforeinstallprompt, which fires once
// per document; the event is kept at module scope so a Turbo navigation does
// not lose it. Safari has no prompt, and the button stays hidden there.
let deferred = null
window.addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault()
  deferred = event
  document.dispatchEvent(new CustomEvent("pwa:installable"))
})

export default class extends Controller {
  connect() {
    this.show = () => (this.element.hidden = !deferred)
    document.addEventListener("pwa:installable", this.show)
    this.show()
  }

  disconnect() {
    document.removeEventListener("pwa:installable", this.show)
  }

  async prompt() {
    if (!deferred) return

    deferred.prompt()
    const { outcome } = await deferred.userChoice
    trackEvent("app_install_prompted", { outcome })
    deferred = null
    this.element.hidden = true
  }
}
