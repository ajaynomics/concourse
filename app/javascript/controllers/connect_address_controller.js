import { Controller } from "@hotwired/stimulus"

// The consent page's address, as the person picks an organization, prefix
// and handle. A namespace belongs to one organization, so only the chosen
// organization's namespaces are offered; the server checks the same rule.
export default class extends Controller {
  static targets = ["organization", "prefix", "handle", "address"]

  connect() {
    this.update()
  }

  update() {
    const organization = this.organizationTargets.find((radio) => radio.checked)?.value ?? ""

    for (const option of this.prefixTarget.options) {
      const owner = option.dataset.organization
      option.hidden = option.disabled = Boolean(owner) && owner !== organization
    }
    if (this.prefixTarget.selectedOptions[0]?.disabled) this.prefixTarget.selectedIndex = 0

    const prefix = this.prefixTarget.selectedOptions[0]?.dataset.prefix ?? ""
    const handle = this.handleTarget.value.trim() || "…"
    this.addressTarget.textContent = `${organization}/${prefix}/${handle}`
  }
}
