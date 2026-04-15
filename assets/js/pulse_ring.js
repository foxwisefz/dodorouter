/**
 * PulseRing Hook
 *
 * Creates a sonar-ping pulse ring effect that emanates from the header area
 * while a request is being processed, giving the whole page an "alive" feeling.
 *
 * - While a request is active: green rings pulse outward every ~1.5s
 * - When the request completes: one final larger ring in the result color
 *   (green=success, orange=fallback, red=error)
 *
 * Listens for the same LiveView push_events used by RequestFlowAnimation:
 *   - "step_started"   → begin pulsing
 *   - "request_completed" → final colored ring, then stop
 */

export const PulseRing = {
  mounted() {
    this.pulseInterval = null
    this.container = null

    this.handleEvent("step_started", () => this.startPulsing())
    this.handleEvent("request_completed", ({status}) => this.finalPulse(status))
  },

  destroyed() {
    this.stopPulsing()
  },

  startPulsing() {
    // Don't restart if already pulsing
    if (this.pulseInterval) return

    this.ensureContainer()

    // Fire a ring immediately
    this.spawnRing()

    // Continue pulsing every 1.5s while the request is active
    this.pulseInterval = setInterval(() => {
      this.spawnRing()
    }, 1500)
  },

  finalPulse(status) {
    this.stopPulsing()

    this.ensureContainer()

    // Spawn one final ring with the result color
    const ring = this.createRing()
    ring.classList.add(`result-${status}`)
    this.container.appendChild(ring)

    // Clean up after the final animation
    ring.addEventListener("animationend", () => {
      ring.remove()
    }, { once: true })
  },

  stopPulsing() {
    if (this.pulseInterval) {
      clearInterval(this.pulseInterval)
      this.pulseInterval = null
    }
  },

  ensureContainer() {
    if (this.container && this.container.parentNode) return

    this.container = document.getElementById("pulse-ring-container")
  },

  createRing() {
    const ring = document.createElement("div")
    ring.className = "pulse-ring"
    return ring
  },

  spawnRing() {
    if (!this.container) return

    const ring = this.createRing()
    this.container.appendChild(ring)

    // Remove the ring after its animation completes
    ring.addEventListener("animationend", () => {
      ring.remove()
    }, { once: true })
  }
}
