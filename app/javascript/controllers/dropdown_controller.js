import { Controller } from "@hotwired/stimulus"

// Closes a <details> dropdown when clicking anywhere outside it.
export default class extends Controller {
  connect() {
    this.onClick = (event) => {
      if (this.element.open && !this.element.contains(event.target)) {
        this.element.open = false
      }
    }
    document.addEventListener("click", this.onClick)
  }

  disconnect() {
    document.removeEventListener("click", this.onClick)
  }
}
