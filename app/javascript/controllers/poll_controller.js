import { Controller } from "@hotwired/stimulus"

// Polls an estimate's status endpoint while it's processing, updating the
// progress bar in place and reloading once it completes or fails. Unlike a
// <meta refresh>, the timer is torn down when the user navigates away.
export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 5000 } }
  static targets = ["bar", "note"]

  connect() {
    this.timer = setInterval(() => this.check(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async check() {
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) return
      const { status, progress, note } = await response.json()
      if (status !== "processing") {
        clearInterval(this.timer)
        window.location.reload()
        return
      }
      if (this.hasBarTarget) this.barTarget.style.width = `${Math.max(progress, 3)}%`
      if (this.hasNoteTarget && note) this.noteTarget.textContent = note
    } catch {
      // transient network error — try again on the next tick
    }
  }
}
