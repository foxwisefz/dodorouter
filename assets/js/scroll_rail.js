// Highlights the rail dash for the message currently in view. The dashes
// and message bubbles share indices (#rail-msg-N <-> #message-N).
export const ScrollRail = {
  mounted() {
    this.activeDash = null
    this.observe()
  },

  updated() {
    // LiveView re-renders (tab switches) replace the bubbles — re-observe
    this.observe()
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
  },

  observe() {
    if (this.observer) this.observer.disconnect()
    this.visible = new Set()

    this.observer = new IntersectionObserver(
      entries => {
        entries.forEach(entry => {
          if (entry.isIntersecting) this.visible.add(entry.target.id)
          else this.visible.delete(entry.target.id)
        })
        this.update()
      },
      // "current" = intersecting a band in the upper third of the viewport,
      // so long messages stay current while you read through them
      {rootMargin: "-15% 0px -70% 0px"}
    )

    document.querySelectorAll('[id^="message-"]').forEach(el => this.observer.observe(el))
  },

  update() {
    if (this.visible.size === 0) return

    const current = [...this.visible]
      .map(id => {
        const el = document.getElementById(id)
        return el ? {id, top: el.getBoundingClientRect().top} : null
      })
      .filter(Boolean)
      .sort((a, b) => a.top - b.top)[0]

    if (!current) return
    const index = +current.id.split("-")[1]

    // dashes are buckets on long conversations — find by range
    const dash = [...this.el.querySelectorAll("[data-from]")].find(
      d => +d.dataset.from <= index && index <= +d.dataset.to
    )
    if (!dash || dash === this.activeDash) return

    if (this.activeDash) this.activeDash.classList.remove("scroll-rail-active")
    dash.classList.add("scroll-rail-active")
    this.activeDash = dash
  }
}
