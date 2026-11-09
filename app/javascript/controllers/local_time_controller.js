import { Controller } from "@hotwired/stimulus"

// Rewrites a <time datetime> into the reader's zone: HH:MM for today, the
// date for anything older, as a departures board would. A morph refresh puts
// the server's UTC text back without reconnecting the controller, so it
// renders again on turbo:morph.
export default class extends Controller {
  connect() {
    this.render = this.render.bind(this)
    document.addEventListener("turbo:morph", this.render)
    this.render()
  }

  disconnect() {
    document.removeEventListener("turbo:morph", this.render)
  }

  render() {
    const at = new Date(this.element.getAttribute("datetime"))
    if (Number.isNaN(at.getTime())) return

    const today = new Date().toDateString() === at.toDateString()
    this.element.textContent = today
      ? at.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
      : at.toLocaleDateString(undefined, { day: "numeric", month: "short" })
  }
}
