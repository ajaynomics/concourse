import { Controller } from "@hotwired/stimulus"

// A <details> menu that closes on an outside click or Escape. The element
// itself does the opening; this only closes it.
export default class extends Controller {
  closeOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  close(event) {
    if (!this.element.open) return
    this.element.open = false
    if (event?.key === "Escape") this.element.querySelector("summary").focus()
  }
}
