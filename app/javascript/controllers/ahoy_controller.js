import { Controller } from "@hotwired/stimulus"
import "ahoy"

// The page-view half of first-party analytics. Rails opens the visit; this
// records the Turbo navigations a server never sees as a full request.
// Configured at module scope because ahoy.js registers its own ready
// handler the moment it is imported.
window.ahoy?.configure({ trackVisits: false })

export default class extends Controller {
  connect() {
    this.recordView = this.recordView.bind(this)
    document.addEventListener("turbo:load", this.recordView)
    this.recordView()
  }

  disconnect() {
    document.removeEventListener("turbo:load", this.recordView)
  }

  // Guarded on the address: connect() and turbo:load fire for the same
  // visit, and a morph refresh from the "tasks" stream is not a navigation.
  recordView() {
    const url = window.location.href
    if (url === this.lastUrl) return

    this.lastUrl = url
    window.ahoy?.trackView()
  }
}
