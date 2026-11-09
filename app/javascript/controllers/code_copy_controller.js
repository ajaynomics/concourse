import { Controller } from "@hotwired/stimulus"
import { trackEvent } from "controllers/analytics_controller"

// Puts a copy button on every code block in the guide. The blocks come from
// JOIN.md, so the buttons are added here rather than in the markdown.
export default class extends Controller {
  static values = { label: String, done: String, failed: String }

  connect() {
    for (const pre of this.element.querySelectorAll("pre")) {
      if (pre.querySelector("[data-code-copy-button]")) {
        pre.querySelector("[data-code-copy-feedback]").textContent = ""
        continue
      }

      const button = document.createElement("button")
      button.type = "button"
      button.dataset.codeCopyButton = ""
      button.dataset.action = "code-copy#copy"
      button.className = "btn-ghost min-h-11 shrink-0 px-3 text-[13px] font-sans"
      button.textContent = this.labelValue
      const feedback = document.createElement("span")
      feedback.dataset.codeCopyFeedback = ""
      feedback.className = "text-[13px] font-sans text-ink-300"
      feedback.setAttribute("role", "status")
      const toolbar = document.createElement("span")
      toolbar.className = "mb-3 flex flex-wrap items-center gap-3 whitespace-normal"
      toolbar.append(button, feedback)
      pre.prepend(toolbar)
    }
  }

  async copy(event) {
    const pre = event.currentTarget.closest("pre")
    const feedback = pre.querySelector("[data-code-copy-feedback]")
    const text = pre.querySelector("code")?.innerText ?? ""
    try {
      await navigator.clipboard.writeText(text)
    } catch {
      feedback.textContent = this.failedValue
      return
    }
    trackEvent("guide_snippet_copied")
    feedback.textContent = this.doneValue
  }
}
