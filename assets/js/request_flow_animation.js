/**
 * RequestFlowAnimation Hook
 *
 * Manages the animated request flow visualization through the routing chain.
 * When a request comes in, a glowing particle travels from step to step,
 * each step card lights up as it's being tried, and the result is shown
 * with satisfying animations.
 *
 * Events received from LiveView:
 *   - "step_started"   → A routing step is being tried
 *   - "step_completed" → A routing step finished (success/fallback/error)
 *   - "request_completed" → The entire request finished
 */

export const RequestFlowAnimation = {
  mounted() {
    this.stepStates = new Map()
    this.particle = null
    this.animationActive = false

    // Listen for LiveView push_event
    this.handleEvent("step_started", (payload) => this.onStepStarted(payload))
    this.handleEvent("step_completed", (payload) => this.onStepCompleted(payload))
    this.handleEvent("request_completed", (payload) => this.onRequestCompleted(payload))

    // Observe DOM changes to handle stream updates
    this.observer = new MutationObserver((mutations) => {
      if (this.animationActive) {
        // Re-apply states when DOM changes (stream updates)
        this.reapplyStates()
      }
    })

    const container = document.getElementById("routing-steps")
    if (container) {
      this.observer.observe(container, { childList: true, subtree: true })
    }
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
    this.removeParticle()
    this.animationActive = false
  },

  onStepStarted({ step_id, step_index, provider, model }) {
    this.animationActive = true

    // Find the step card by data-step-id
    const stepEl = document.querySelector(`[data-step-id="${step_id}"]`)

    if (stepEl) {
      const card = stepEl.querySelector(".step-card")
      const ring = stepEl.querySelector(".step-number-ring")

      // Set trying state
      if (card) card.dataset.status = "trying"
      if (ring) ring.dataset.status = "trying"

      // Add status indicator
      this.addStatusIndicator(stepEl, "trying")

      // Move particle to this step
      this.moveParticleToStep(stepEl)

      // Activate the connector from previous step
      this.activateConnectorToStep(step_index)
    }
  },

  onStepCompleted({ step_id, status, latency_ms }) {
    const stepEl = document.querySelector(`[data-step-id="${step_id}"]`)

    if (stepEl) {
      const card = stepEl.querySelector(".step-card")
      const ring = stepEl.querySelector(".step-number-ring")

      // Store the state
      this.stepStates.set(step_id, status)

      // Set completed state
      if (card) card.dataset.status = status
      if (ring) ring.dataset.status = status

      // Update status indicator
      this.updateStatusIndicator(stepEl, status)

      // Update connector color
      this.setConnectorStatus(stepEl, status)
    }
  },

  onRequestCompleted({ status }) {
    // After a brief delay, clean up the animation
    setTimeout(() => {
      this.resetAnimation()
    }, 2000)
  },

  reapplyStates() {
    // Re-apply step states after DOM updates
    for (const [stepId, status] of this.stepStates) {
      const stepEl = document.querySelector(`[data-step-id="${stepId}"]`)
      if (stepEl) {
        const card = stepEl.querySelector(".step-card")
        const ring = stepEl.querySelector(".step-number-ring")
        if (card) card.dataset.status = status
        if (ring) ring.dataset.status = status
      }
    }
  },

  moveParticleToStep(stepEl) {
    const container = document.getElementById("routing-steps")
    if (!container) return

    // Create particle if it doesn't exist
    if (!this.particle) {
      this.particle = document.createElement("div")
      this.particle.className = "flow-particle"
      container.appendChild(this.particle)
    }

    // Position the particle at the step card
    const card = stepEl.querySelector(".step-card")
    if (!card) return

    const containerRect = container.getBoundingClientRect()
    const cardRect = card.getBoundingClientRect()

    // Position at the left edge of the card, vertically centered
    const top = cardRect.top - containerRect.top + cardRect.height / 2 - 4
    const left = cardRect.left - containerRect.left - 16

    this.particle.style.top = `${top}px`
    this.particle.style.left = `${Math.max(0, left)}px`
  },

  activateConnectorToStep(stepIndex) {
    // Light up the connector leading to this step
    const connector = document.querySelector(
      `[data-connector-index="${stepIndex}"]`
    )
    if (connector) {
      connector.dataset.status = "active"
    }
  },

  setConnectorStatus(stepEl, status) {
    const stepIndex = stepEl.dataset.stepIndex
    const nextIndex = parseInt(stepIndex) + 1

    // Set the connector AFTER this step to show flow direction
    const connectorAfter = document.querySelector(
      `[data-connector-index="${nextIndex}"]`
    )
    if (connectorAfter && status === "fallback") {
      connectorAfter.dataset.status = "active"
    }

    // Set the connector leading TO this step
    const connectorBefore = document.querySelector(
      `[data-connector-index="${stepIndex}"]`
    )
    if (connectorBefore) {
      connectorBefore.dataset.status = status
    }
  },

  addStatusIndicator(stepEl, status) {
    // Remove existing indicator
    const existing = stepEl.querySelector(".step-status-indicator")
    if (existing) existing.remove()

    const card = stepEl.querySelector(".step-card")
    if (!card) return

    const indicator = document.createElement("div")
    indicator.className = `step-status-indicator ${status}`

    if (status === "trying") {
      // Spinning dots indicator
      indicator.innerHTML = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3">
        <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83" />
      </svg>`
    }

    card.style.position = "relative"
    card.appendChild(indicator)
  },

  updateStatusIndicator(stepEl, status) {
    const indicator = stepEl.querySelector(".step-status-indicator")
    if (!indicator) {
      this.addStatusIndicator(stepEl, status)
      return
    }

    indicator.className = `step-status-indicator ${status}`

    if (status === "success") {
      indicator.innerHTML = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3">
        <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
      </svg>`
    } else if (status === "fallback") {
      indicator.innerHTML = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3">
        <path stroke-linecap="round" stroke-linejoin="round" d="M13 5l7 7-7 7M5 5l7 7-7 7" />
      </svg>`
    } else if (status === "error") {
      indicator.innerHTML = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3">
        <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
      </svg>`
    }
  },

  removeParticle() {
    if (this.particle) {
      this.particle.remove()
      this.particle = null
    }
  },

  resetAnimation() {
    this.animationActive = false
    this.stepStates.clear()
    this.removeParticle()

    // Clear all step statuses
    document.querySelectorAll(".step-card[data-status]").forEach((el) => {
      delete el.dataset.status
    })
    document.querySelectorAll(".step-number-ring[data-status]").forEach((el) => {
      delete el.dataset.status
    })
    document.querySelectorAll(".step-connector[data-status]").forEach((el) => {
      delete el.dataset.status
    })
    document.querySelectorAll(".step-status-indicator").forEach((el) => {
      el.remove()
    })
  }
}
