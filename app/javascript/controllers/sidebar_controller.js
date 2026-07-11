import { Controller } from "@hotwired/stimulus"

// Collapsible sidebar: toggles between full (w-56) and icon rail (w-16),
// persisted in localStorage so the choice survives navigation.
export default class extends Controller {
  static targets = ["aside", "main", "label"]

  connect() {
    this.collapsed = localStorage.getItem("muster:sidebar") === "collapsed"
    this.apply()
  }

  toggle() {
    this.collapsed = !this.collapsed
    localStorage.setItem("muster:sidebar", this.collapsed ? "collapsed" : "open")
    this.apply()
  }

  apply() {
    this.asideTarget.classList.toggle("w-56", !this.collapsed)
    this.asideTarget.classList.toggle("w-16", this.collapsed)
    this.mainTarget.classList.toggle("ml-56", !this.collapsed)
    this.mainTarget.classList.toggle("ml-16", this.collapsed)
    this.labelTargets.forEach(el => el.classList.toggle("hidden", this.collapsed))
  }
}
