import { Controller } from "@hotwired/stimulus"

// Pre-ticks the re-cost checklist as the user edits: a field (or container)
// carrying data-recost-sections="A|B" ticks those sections; "*" ticks all.
// Auto-ticking never marks the checklist as "submitted" — the hidden field
// stays blank so the server can fall back to its own computed default when
// nothing was manually chosen. Only a deliberate action (ticking/unticking a
// box by hand, or Tick all/none) sets submitted="1", so that choice wins.
export default class extends Controller {
  static targets = ["section", "submitted"]

  touch(event) {
    const carrier = event.target.closest("[data-recost-sections]")
    if (!carrier) return
    const spec = carrier.dataset.recostSections
    const names = spec === "*" ? null : spec.split("|")
    this.sectionTargets.forEach((box) => {
      if (names === null || names.includes(box.dataset.section)) box.checked = true
    })
  }

  manual() {
    this.submittedTarget.value = "1"
  }

  all(event) {
    event.preventDefault()
    this.sectionTargets.forEach((b) => (b.checked = true))
    this.submittedTarget.value = "1"
  }

  none(event) {
    event.preventDefault()
    this.sectionTargets.forEach((b) => (b.checked = false))
    this.submittedTarget.value = "1"
  }
}
