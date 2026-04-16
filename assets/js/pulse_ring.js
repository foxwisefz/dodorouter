/**
 * PulseRing Hook (notification bar indicator)
 *
 * Shows a horizontal notification bar that drops down from the top of the page
 * when requests are in-flight.
 */

export const PulseRing = {
  mounted() {
    this.bar = null
    this.countEl = null
    this.activeRequests = []
    this.removeTimer = null

    this.handleEvent("step_started", (payload) => {
      console.log("L16 step_started");
      if (payload.step_index == 0 && payload.request_id) {
        this.activeRequests.push(payload.request_id)
        this.showBar()
        this.updateCount()
      }
    })

    this.handleEvent("request_completed", ({request_id, status}) => {
      console.log("L25 request_completed");
      if (request_id) {
        this.activeRequests.pop()
      }

      if (this.activeRequests.length === 0 && this.bar) {
        console.log("L31 removing bar")
        this.startRemoval(status)
      } else {
        console.log("L34 updating count")
        this.updateCount()
      }
    })
  },

  destroyed() {
    if (this.removeTimer) clearTimeout(this.removeTimer)
    this.removeBar()
  },

  showBar() {
    if (this.bar) {
      if (!document.contains(this.bar)) {
        this.bar = null
        this.countEl = null
      } else {
        if (this.removeTimer) {
          clearTimeout(this.removeTimer)
          this.removeTimer = null
        }
        this.bar.className = "request-peek-bar active"
        return
      }
    }

    // Create fresh bar
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

  startRemoval(status) {
    if (this.removeTimer) {
      clearTimeout(this.removeTimer)
    }

    this.bar.classList.remove("active")
    void this.bar.offsetHeight
    this.bar.classList.add(`result-${status}`)

    this.removeTimer = setTimeout(() => {
      this.removeBar()
      this.removeTimer = null
    }, 1000)
  },

  updateCount() {
    if (!this.countEl) return

    const count = this.activeRequests.length
    if (count === 1) {
      this.countEl.textContent = "Processing 1 request"
    } else {
      this.countEl.textContent = `Processing ${count} requests`
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
