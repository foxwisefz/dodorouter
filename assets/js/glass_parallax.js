/**
 * GlassParallax Hook
 *
 * Adds Apple TV+-style 3D tilt/parallax effect to glass cards on hover.
 * Uses event delegation on the page container — no per-card hook needed.
 *
 * Cards with `data-glass-card` attribute get:
 *  - A specular highlight overlay that follows the mouse
 *  - Subtle 3D perspective tilt based on mouse position
 *  - Smooth spring-back animation when mouse leaves
 *
 * Usage in template:
 *   <div id="router-show-page" phx-hook="GlassParallax">
 *     <div class="stat-card" data-glass-card>...</div>
 *     <div class="card-bordered" data-glass-card>...</div>
 *   </div>
 */

const MAX_TILT = 8        // degrees
const PERSPECTIVE = 800    // px
const TRANSITION_MS = 400  // smooth return on mouse leave

export const GlassParallax = {
  mounted() {
    this.el.style.perspective = `${PERSPECTIVE}px`

    this._onMouseMove = this._onMouseMove.bind(this)
    this._onMouseLeave = this._onMouseLeave.bind(this)

    // Use event delegation on the container
    this.el.addEventListener("mousemove", this._onMouseMove)
    this.el.addEventListener("mouseleave", this._onMouseLeave)
  },

  destroyed() {
    this.el.removeEventListener("mousemove", this._onMouseMove)
    this.el.removeEventListener("mouseleave", this._onMouseLeave)
  },

  _findCard(target) {
    return target.closest("[data-glass-card]")
  },

  _ensureSpecular(card) {
    let spec = card.querySelector(".glass-specular")
    if (!spec) {
      spec = document.createElement("div")
      spec.className = "glass-specular"
      card.appendChild(spec)
    }
    return spec
  },

  _onMouseMove(e) {
    const card = this._findCard(e.target)
    if (!card) return

    // Skip cards inside the routing chain that have their own animation overlays
    if (card.closest("#routing-chain-container")) return

    const rect = card.getBoundingClientRect()
    const x = e.clientX - rect.left
    const y = e.clientY - rect.top
    const centerX = rect.width / 2
    const centerY = rect.height / 2

    // Calculate tilt angles (invert Y for natural feel)
    const tiltX = ((y - centerY) / centerY) * -MAX_TILT
    const tiltY = ((x - centerX) / centerX) * MAX_TILT

    // Apply transform with smooth transition disabled during movement
    card.classList.add("glass-tilting")
    card.style.transition = "transform 0.1s ease-out"
    card.style.transform = `rotateX(${tiltX}deg) rotateY(${tiltY}deg) scale3d(1.02, 1.02, 1.02)`

    // Update specular highlight position
    const specular = this._ensureSpecular(card)
    const percentX = (x / rect.width) * 100
    const percentY = (y / rect.height) * 100
    specular.style.setProperty("--specular-x", `${percentX}%`)
    specular.style.setProperty("--specular-y", `${percentY}%`)
  },

  _onMouseLeave(e) {
    // Reset all glass cards in the container
    const cards = this.el.querySelectorAll("[data-glass-card].glass-tilting")
    cards.forEach(card => {
      card.classList.remove("glass-tilting")
      card.style.transition = `transform ${TRANSITION_MS}ms cubic-bezier(0.25, 0.46, 0.45, 0.94)`
      card.style.transform = "rotateX(0deg) rotateY(0deg) scale3d(1, 1, 1)"

      // Hide specular
      const specular = card.querySelector(".glass-specular")
      if (specular) {
        specular.style.opacity = "0"
      }
    })
  }
}
