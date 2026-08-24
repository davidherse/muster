import { Controller } from "@hotwired/stimulus"

// Steps through the clarifying-questions wizard: one question at a time,
// skip clears the answer, the final step submits the whole form at once.
export default class extends Controller {
  static targets = ["step", "counter", "bar", "backButton", "nextButton", "submitButton", "input"]

  connect() {
    this.index = 0
    this.render()
  }

  next() {
    if (this.index < this.stepTargets.length - 1) {
      this.index++
      this.render()
    }
  }

  skip() {
    const input = this.inputTargets[this.index]
    if (input) input.value = ""
    if (this.index === this.stepTargets.length - 1) {
      this.element.querySelector("form").requestSubmit()
    } else {
      this.next()
    }
  }

  back() {
    if (this.index > 0) {
      this.index--
      this.render()
    }
  }

  render() {
    const last = this.stepTargets.length - 1
    this.stepTargets.forEach((step, i) => step.classList.toggle("hidden", i !== this.index))
    this.counterTarget.textContent = this.index + 1
    this.barTarget.style.width = `${(this.index / this.stepTargets.length) * 100}%`
    this.backButtonTarget.classList.toggle("invisible", this.index === 0)
    // ui_button carries inline-flex, which outranks the `hidden` utility in
    // the compiled CSS — inline display is the only reliable toggle here.
    this.nextButtonTarget.style.display = this.index === last ? "none" : ""
    this.submitButtonTarget.style.display = this.index === last ? "" : "none"
  }
}
