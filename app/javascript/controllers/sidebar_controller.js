import { Controller } from "@hotwired/stimulus"

// Collapsible sidebar: full (w-56) or icon rail (w-16), persisted in
// localStorage. Collapsed mode hides labels and the logo, and centres the
// toggle, nav icons and avatar so the rail reads as a clean icon column.
export default class extends Controller {
  static targets = ["aside", "main", "label", "item", "header"]

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
    this.itemTargets.forEach(el => {
      el.classList.toggle("justify-center", this.collapsed)
      el.classList.toggle("px-2.5", !this.collapsed)
      el.classList.toggle("px-0", this.collapsed)
    })
    if (this.hasHeaderTarget) {
      this.headerTarget.classList.toggle("justify-between", !this.collapsed)
      this.headerTarget.classList.toggle("justify-center", this.collapsed)
    }
  }
}
