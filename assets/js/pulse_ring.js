/**
 * PulseRing Hook (now a notification bar indicator)
 *
 * Shows a horizontal notification bar that drops down from the top of the page
 * when requests are in-flight. Displays "Processing X request(s)" with a
 * pulsing dot. Supports concurrent requests with a live counter.
 */

export const PulseRing = {
  mounted() {
    this.bar = null
    this.countEl = null
    this.activeCount = 0

    this.handleEvent("step_started", () => this.onRequestStart())
    this.handleEvent("request_completed", ({status}) => this.onRequestComplete(status))
  },

  destroyed() {
    this.removeBar()
  },

  onRequestStart() {
    this.activeCount++

    if (!this.bar) {
      this.createBar()
    }

    this.updateCount()
  },

  onRequestComplete(status) {
    if (this.activeCount > 0) {
      this.activeCount--
    }

    if (this.activeCount === 0 && this.bar) {
      // No more active requests — flash result and remove
      this.bar.classList.remove("active")
      this.bar.classList.add(`result-${status}`)

      this.bar.addEventListener("animationend", () => {
        this.removeBar()
      }, { once: true })

      // Safety cleanup
      setTimeout(() => this.removeBar(), 1200)
    } else if (this.bar) {
      this.updateCount()
    }
  },

  createBar() {
    this.bar = document.createElement("div")
    this.bar.className = "request-peek-bar active"

    const dot = document.createElement("span")
    dot.className = "pulse-dot"

    this.countEl = document.createElement("span")
    this.countEl.className = "request-count-text"

    this.bar.appendChild(dot)
    this.bar.appendChild(this.countEl)

    this.el.prepend(this.bar)
  },

  updateCount() {
    if (!this.countEl) return

    if (this.activeCount === 1) {
      this.countEl.textContent = "Processing 1 request"
    } else {
      this.countEl.textContent = `Processing ${this.activeCount} requests`
    }
  },

  removeBar() {
    if (this.bar && this.bar.parentNode) {
      this.bar.remove()
    }
    this.bar = null
    this.countEl = null
  }
}
