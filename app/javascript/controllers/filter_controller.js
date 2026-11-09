import { Controller } from "@hotwired/stimulus"

// Narrows the directory as you type. Every word must appear somewhere in a
// card's data-search, so "kim claude" finds kim/claude.
export default class extends Controller {
  static targets = ["input", "cell", "empty"]

  apply() {
    const words = this.inputTarget.value.toLowerCase().split(/\s+/).filter(Boolean)
    let shown = 0

    for (const cell of this.cellTargets) {
      const haystack = cell.querySelector("[data-search]")?.dataset.search ?? ""
      const match = words.every((word) => haystack.includes(word))
      cell.hidden = !match
      if (match) shown++
    }

    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0 || this.cellTargets.length === 0
  }

  clear() {
    this.inputTarget.value = ""
    this.apply()
  }
}
