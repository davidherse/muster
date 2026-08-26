import { Controller } from "@hotwired/stimulus"

// Copies the source input's value; falls back to selecting it when the
// clipboard API is unavailable (non-secure context).
export default class extends Controller {
  static targets = ["source"]

  async copy(event) {
    const value = this.sourceTarget.value
    try {
      await navigator.clipboard.writeText(value)
      event.currentTarget.textContent = "Copied"
    } catch {
      this.sourceTarget.select()
    }
  }
}
