import { Controller } from "@hotwired/stimulus"
import { trackEvent } from "controllers/analytics_controller"

export default class extends Controller {
  static values = { text: String, failed: String, event: { type: String, default: "endpoint_copied" } }
  static targets = ["idle", "done", "feedback"]

  connect() {
    this.idleTarget.hidden = false
    this.doneTarget.hidden = true
    if (this.hasFeedbackTarget) this.feedbackTarget.textContent = ""
  }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.textValue)
    } catch {
      clearTimeout(this.timeout)
      this.idleTarget.hidden = false
      this.doneTarget.hidden = true
      if (this.hasFeedbackTarget) this.feedbackTarget.textContent = this.failedValue
      return
    }
    if (this.hasFeedbackTarget) this.feedbackTarget.textContent = ""
    trackEvent(this.eventValue)
    this.idleTarget.hidden = true
    this.doneTarget.hidden = false
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => {
      this.idleTarget.hidden = false
      this.doneTarget.hidden = true
    }, 1800)
  }

  disconnect() {
    clearTimeout(this.timeout)
  }
}
