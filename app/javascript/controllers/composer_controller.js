import { Controller } from "@hotwired/stimulus"

// ⌘/Ctrl+Enter sends the reply, as in every chat box.
export default class extends Controller {
  static targets = ["submit"]

  submit(event) {
    event.preventDefault()
    this.element.requestSubmit(this.hasSubmitTarget ? this.submitTarget : undefined)
  }
}
