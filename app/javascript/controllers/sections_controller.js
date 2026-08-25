import { Controller } from "@hotwired/stimulus"

// Row controls for the template edit form: add a section from the blueprint
// <template>, remove a row, move it up or down. Row numbers are re-stamped
// after every change so the list reads in order.
export default class extends Controller {
  static targets = ["list", "row", "blueprint", "index"]

  connect() { this.renumber() }

  add() {
    const row = this.blueprintTarget.content.firstElementChild.cloneNode(true)
    this.listTarget.appendChild(row)
    row.querySelector("input[type=text]").focus()
    this.renumber()
  }

  remove(event) {
    this.rowFor(event).remove()
    this.renumber()
  }

  up(event) {
    const row = this.rowFor(event)
    const previous = row.previousElementSibling
    if (previous) this.listTarget.insertBefore(row, previous)
    this.renumber()
  }

  down(event) {
    const row = this.rowFor(event)
    const next = row.nextElementSibling
    if (next) this.listTarget.insertBefore(next, row)
    this.renumber()
  }

  rowFor(event) {
    return event.currentTarget.closest("[data-sections-target='row']")
  }

  renumber() {
    this.rowTargets.forEach((row, i) => {
      const index = row.querySelector("[data-sections-target='index']")
      if (index) index.textContent = i + 1
    })
  }
}
