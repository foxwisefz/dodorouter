export const CopyButton = {
  mounted() {
    this.original = this.el.innerHTML
    this.el.addEventListener("click", async (e) => {
      e.preventDefault()
      e.stopPropagation()
      const text = this.el.dataset.copy || ""
      try {
        await navigator.clipboard.writeText(text)
        this.el.textContent = "copied"
        clearTimeout(this._t)
        this._t = setTimeout(() => { this.el.innerHTML = this.original }, 1200)
      } catch (_) {
        this.el.textContent = "copy failed"
      }
    })
  }
}
