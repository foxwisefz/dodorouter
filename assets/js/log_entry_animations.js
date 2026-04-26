/**
 * LogEntryAnimations Hook
 *
 * Manages slide-in and shimmer animations for the Recent Logs stream.
 *
 * - New log entries (pending) slide in from the left with a spring animation
 * - Pending entries get a shimmer loading effect
 * - When a pending entry is replaced by a completed one, it gets a flash glow
 *
 * Works by observing DOM mutations on the #recent-logs stream container.
 * Phoenix streams replace DOM elements in-place using the same ID, so we
 * detect transitions by tracking which IDs were previously in "pending" state.
 */

export const LogEntryAnimations = {
  mounted() {
    // Track which log IDs are currently pending
    this.pendingIds = new Set()
    // Track which log IDs we've already seen (to distinguish new vs existing)
    this.knownIds = new Set()

    // Mark all existing log entries as known (no animation on page load)
    const container = document.getElementById("recent-logs")
    if (container) {
      container.querySelectorAll("[id]").forEach((el) => {
        if (el.closest("[phx-update='stream']") || el.hasAttribute("id")) {
          this.knownIds.add(el.id)
        }
      })
    }

    // Observe DOM changes to detect new/updated log entries
    this.observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (node.nodeType !== Node.ELEMENT_NODE) continue
          this.handleNewNode(node)
        }

        // Handle attribute changes (phx-update may update classes)
        if (mutation.type === "attributes") {
          this.handleAttributeChange(mutation.target)
        }
      }
    })

    if (container) {
      this.observer.observe(container, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["class", "data-status"]
      })
    }
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
  },

  handleNewNode(node) {
    // Check if this is a log entry (direct child of the stream with an id)
    const logEntries = node.matches?.("[id]") ? [node] :
      Array.from(node.querySelectorAll?.("[id]") || [])

    for (const entry of logEntries) {
      // Skip if not a direct log entry in the stream
      const parent = entry.parentElement
      if (!parent || parent.id !== "recent-logs") continue

      const isNew = !this.knownIds.has(entry.id)

      if (isNew) {
        this.knownIds.add(entry.id)

        // Check if it's a pending entry
        const isPending = this.isPendingEntry(entry)

        if (isPending) {
          this.pendingIds.add(entry.id)
          // Slide in + shimmer
          entry.classList.add("log-entry-new")
          // Add shimmer after slide-in completes
          entry.addEventListener("animationend", () => {
            entry.classList.remove("log-entry-new")
            entry.classList.add("log-entry-pending")
          }, { once: true })
        } else {
          // Non-pending new entry (shouldn't happen normally, but just slide in)
          entry.classList.add("log-entry-new")
          entry.addEventListener("animationend", () => {
            entry.classList.remove("log-entry-new")
          }, { once: true })
        }
      } else {
        // Existing entry was updated (e.g., pending → completed)
        const wasPending = this.pendingIds.has(entry.id)

        if (wasPending) {
          this.pendingIds.delete(entry.id)

          // Remove pending state
          entry.classList.remove("log-entry-pending", "animate-pulse")

          // Determine completion status and flash
          const status = this.getEntryStatus(entry)
          if (status) {
            entry.classList.add(`log-entry-completed-${status}`)

            // Clean up after animation
            entry.addEventListener("animationend", () => {
              entry.classList.remove(`log-entry-completed-${status}`)
            }, { once: true })
          }
        }
      }
    }
  },

  handleAttributeChange(target) {
    // Not needed for current implementation, but available for future use
  },

  isPendingEntry(el) {
    // Check if the entry has pending-related classes or content
    const classes = el.className || ""
    return classes.includes("pending") || classes.includes("animate-pulse")
  },

  getEntryStatus(el) {
    // Determine the completion status from the element's classes
    const classes = el.className || ""
    if (classes.includes("bg-success")) return "success"
    if (classes.includes("bg-warning")) return "fallback"
    if (classes.includes("bg-error")) return "error"
    return null
  }
}
