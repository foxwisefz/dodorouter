// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/dodo_router"
import {RequestFlowAnimation} from "./request_flow_animation"
import {LogEntryAnimations} from "./log_entry_animations"
import {PulseRing} from "./pulse_ring"
import {CopyButton} from "./copy_button"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, RequestFlowAnimation, LogEntryAnimations, PulseRing, CopyButton},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
let pendingRequests = 0

function applySidebarState(collapsed) {
  const sidebar = document.getElementById("desktop-sidebar")
  const main = document.getElementById("main-content")
  if (!sidebar || !main) return

  if (collapsed) {
    sidebar.classList.remove("w-56")
    sidebar.classList.add("w-16")
    sidebar.setAttribute("data-collapsed", "true")
    main.classList.remove("lg:ml-56")
    main.classList.add("lg:ml-16")
    sidebar.querySelectorAll(".sidebar-label").forEach(el => el.classList.add("hidden"))
    sidebar.querySelectorAll(".sidebar-section").forEach(el => el.classList.add("hidden"))
    sidebar.querySelectorAll(".sidebar-item").forEach(el => el.classList.add("justify-center", "px-0"))
    sidebar.querySelectorAll(".sidebar-item").forEach(el => el.classList.remove("px-3"))
  } else {
    sidebar.classList.remove("w-16")
    sidebar.classList.add("w-56")
    sidebar.setAttribute("data-collapsed", "false")
    main.classList.remove("lg:ml-16")
    main.classList.add("lg:ml-56")
    sidebar.querySelectorAll(".sidebar-label").forEach(el => el.classList.remove("hidden"))
    sidebar.querySelectorAll(".sidebar-section").forEach(el => el.classList.remove("hidden"))
    sidebar.querySelectorAll(".sidebar-item").forEach(el => el.classList.remove("justify-center", "px-0"))
    sidebar.querySelectorAll(".sidebar-item").forEach(el => el.classList.add("px-3"))
  }
}

function savePreference(payload) {
  fetch("/preferences", {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      "x-csrf-token": document.querySelector("meta[name='csrf-token']")?.getAttribute("content"),
    },
    body: JSON.stringify(payload),
  }).catch(() => {})
}

window.addEventListener("phx:page-loading-start", _info => {
  pendingRequests++
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", _info => {
  pendingRequests = Math.max(0, pendingRequests - 1)
  if (pendingRequests === 0) {
    topbar.hide()
  }
  const sidebar = document.getElementById("desktop-sidebar")
  if (sidebar?.getAttribute("data-collapsed") === "true") {
    applySidebarState(true)
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

window.addEventListener("phx:set-theme", (e) => {
  const theme = e.target.dataset.phxTheme
  const resolved = theme === "system"
    ? (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")
    : theme
  document.documentElement.setAttribute("data-theme", resolved)
  savePreference({theme})
})

document.addEventListener("DOMContentLoaded", () => {
  const sidebar = document.getElementById("desktop-sidebar")
  if (sidebar?.getAttribute("data-collapsed") === "true") {
    applySidebarState(true)
  }

  document.addEventListener("click", (e) => {
    const toggle = e.target.closest("#sidebar-toggle")
    if (!toggle) return

    const sidebar = document.getElementById("desktop-sidebar")
    const isCollapsed = sidebar?.getAttribute("data-collapsed") === "true"
    const newState = !isCollapsed
    applySidebarState(newState)
    savePreference({sidebar_collapsed: newState})
  })

  const goToItems = [
    {label: "Dashboard", path: "/dashboard", icon: "home", keywords: ["home", "dashboard"]},
    {label: "Requests", path: "/logs", icon: "clock", keywords: ["logs", "requests", "log", "request"]},
    {label: "Routers", path: "/routers", icon: "adjustments-horizontal", keywords: ["routers", "router"]},
    {label: "API Keys", path: "/api-keys", icon: "key", keywords: ["api", "keys", "key", "tokens"]},
    {label: "Providers", path: "/providers", icon: "server", keywords: ["providers", "provider"]},
    {label: "Settings", path: "/users/settings", icon: "cog-6-tooth", keywords: ["settings", "config", "preferences"]},
  ]

  const modal = document.getElementById("go-to-modal")
  const input = document.getElementById("go-to-input")
  const results = document.getElementById("go-to-results")
  const backdrop = document.getElementById("go-to-backdrop")
  const trigger = document.getElementById("go-to-trigger")
  let activeIndex = -1

  function openModal() {
    modal.classList.remove("hidden")
    input.value = ""
    renderItems(goToItems)
    activeIndex = -1
    setTimeout(() => input.focus(), 0)
  }

  function closeModal() {
    modal.classList.add("hidden")
    input.value = ""
    activeIndex = -1
  }

  function renderItems(items) {
    results.innerHTML = items.map((item, i) => `
      <li>
        <a href="${item.path}" data-index="${i}"
           class="go-to-item flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm text-base-content/70 hover:bg-accent/10 hover:text-accent transition-colors">
          <span class="flex items-center justify-center size-5 text-base-content/40">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4">
              <path stroke-linecap="round" stroke-linejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25" />
            </svg>
          </span>
          ${item.label}
        </a>
      </li>
    `).join("")
    activeIndex = -1
  }

  function updateActive(items) {
    const els = results.querySelectorAll(".go-to-item")
    els.forEach((el, i) => {
      el.classList.toggle("bg-accent/10", i === activeIndex)
      el.classList.toggle("text-accent", i === activeIndex)
    })
    if (els[activeIndex]) els[activeIndex].scrollIntoView({block: "nearest"})
  }

  trigger?.addEventListener("click", openModal)
  backdrop?.addEventListener("click", closeModal)

  input?.addEventListener("input", () => {
    const q = input.value.toLowerCase().trim()
    if (!q) { renderItems(goToItems); return }
    const filtered = goToItems.filter(item =>
      item.label.toLowerCase().includes(q) ||
      item.keywords.some(k => k.includes(q))
    )
    renderItems(filtered)
    activeIndex = -1
  })

  input?.addEventListener("keydown", (e) => {
    const items = results.querySelectorAll(".go-to-item")
    if (e.key === "ArrowDown") {
      e.preventDefault()
      activeIndex = Math.min(activeIndex + 1, items.length - 1)
      updateActive(items)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      activeIndex = Math.max(activeIndex - 1, 0)
      updateActive(items)
    } else if (e.key === "Enter" && activeIndex >= 0 && items[activeIndex]) {
      e.preventDefault()
      items[activeIndex].click()
    } else if (e.key === "Escape") {
      closeModal()
    }
  })

  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "k") {
      e.preventDefault()
      if (modal.classList.contains("hidden")) {
        openModal()
      } else {
        closeModal()
      }
    }
    if (e.key === "Escape" && !modal.classList.contains("hidden")) {
      closeModal()
    }
  })
})

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

