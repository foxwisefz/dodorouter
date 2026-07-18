// Hover/focus tooltip layer for dashboard charts.
//
// Any descendant with a `data-viz-tip` JSON payload ({title, rows: [{label,
// value, color}]}) gets a floating tooltip. Containers with
// `data-viz-crosshair` also show a vertical hairline (a `.viz-crosshair`
// element rendered by the chart) snapped to the hovered bucket. Events are
// delegated from the container so LiveView re-renders never detach handlers;
// the tooltip element itself lives on <body>, outside LiveView-managed DOM.
// All payload text is inserted via textContent — never innerHTML.
export const VizTooltip = {
  mounted() {
    this.tooltip = document.createElement("div")
    this.tooltip.className = "viz-tooltip"
    document.body.appendChild(this.tooltip)

    this.onOver = (e) => {
      const target = e.target.closest("[data-viz-tip]")
      if (!target || !this.el.contains(target)) return this.hide()
      this.show(target)
      this.position(e.clientX, e.clientY, target)
    }
    this.onMove = (e) => {
      const target = e.target.closest("[data-viz-tip]")
      if (target) this.position(e.clientX, e.clientY, target)
    }
    this.onLeave = () => this.hide()
    this.onFocusIn = (e) => {
      const target = e.target.closest("[data-viz-tip]")
      if (!target) return
      this.show(target)
      const rect = target.getBoundingClientRect()
      this.position(rect.left + rect.width / 2, rect.top, target)
    }

    this.el.addEventListener("pointerover", this.onOver)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerleave", this.onLeave)
    this.el.addEventListener("focusin", this.onFocusIn)
    this.el.addEventListener("focusout", this.onLeave)
  },

  destroyed() {
    this.tooltip?.remove()
  },

  show(target) {
    let payload
    try {
      payload = JSON.parse(target.dataset.vizTip)
    } catch {
      return this.hide()
    }

    this.tooltip.replaceChildren()

    if (payload.title) {
      const title = document.createElement("p")
      title.className = "mb-1 font-medium text-base-content/60"
      title.textContent = payload.title
      this.tooltip.appendChild(title)
    }

    for (const row of payload.rows || []) {
      const line = document.createElement("div")
      line.className = "flex items-center gap-1.5 py-px"

      if (row.color) {
        const key = document.createElement("span")
        key.className = "h-0.5 w-3 shrink-0 rounded-full"
        key.style.background = row.color
        line.appendChild(key)
      }

      const value = document.createElement("span")
      value.className = "font-semibold tabular-nums"
      value.textContent = row.value
      const label = document.createElement("span")
      label.className = "text-base-content/60"
      label.textContent = row.label

      // Values lead, labels follow
      if (row.value) line.appendChild(value)
      line.appendChild(label)
      this.tooltip.appendChild(line)
    }

    this.tooltip.setAttribute("data-show", "")
    this.moveCrosshair(target)
  },

  hide() {
    this.tooltip.removeAttribute("data-show")
    const hair = this.el.querySelector(".viz-crosshair")
    if (hair) hair.classList.add("hidden")
  },

  position(x, y, target) {
    const {offsetWidth: w, offsetHeight: h} = this.tooltip
    const pad = 12
    let left = x + pad
    let top = y - h - pad
    if (left + w > window.innerWidth - pad) left = x - w - pad
    if (top < pad) top = y + pad
    this.tooltip.style.left = `${Math.max(pad, left)}px`
    this.tooltip.style.top = `${top}px`
    this.moveCrosshair(target)
  },

  moveCrosshair(target) {
    if (!this.el.hasAttribute("data-viz-crosshair")) return
    const hair = this.el.querySelector(".viz-crosshair")
    if (!hair || !target.hasAttribute("data-viz-x")) return
    const slotRect = target.getBoundingClientRect()
    const plotRect = hair.parentElement.getBoundingClientRect()
    hair.style.left = `${slotRect.left - plotRect.left + slotRect.width / 2}px`
    hair.classList.remove("hidden")
  },
}
