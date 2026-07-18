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
import {CopyButton} from "./copy_button"
import {ScrollRail} from "./scroll_rail"
import {VizTooltip} from "./viz_tooltip"

const ScrollIntoView = {
  mounted() {
    this.el.scrollIntoView({behavior: "smooth", block: "center"})
  }
}
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, RequestFlowAnimation, LogEntryAnimations, CopyButton, ScrollIntoView, ScrollRail, VizTooltip},
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

  const staticItems = [
    {label: "Dashboard", path: "/dashboard", icon: "home", keywords: ["home", "dashboard"]},
    {label: "Requests", path: "/logs", icon: "clock", keywords: ["logs", "requests", "log", "request"]},
    {label: "Evaluations", path: "/evals", icon: "beaker", keywords: ["evals", "evaluation", "quality", "judge"]},
    {label: "Routers", path: "/routers", icon: "adjustments-horizontal", keywords: ["routers", "router"]},
    {label: "API Keys", path: "/api-keys", icon: "key", keywords: ["api", "keys", "key", "tokens"]},
    {label: "Providers", path: "/providers", icon: "server", keywords: ["providers", "provider"]},
    {label: "Settings", path: "/users/settings", icon: "cog-6-tooth", keywords: ["settings", "config", "preferences"]},
  ]

  const heroIcons = {
    "home": '<path stroke-linecap="round" stroke-linejoin="round" d="m2.25 12 8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75M8.25 21h8.25"/>',
    "clock": '<path stroke-linecap="round" stroke-linejoin="round" d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"/>',
    "beaker": '<path stroke-linecap="round" stroke-linejoin="round" d="M14.25 6.087c0-.355.186-.676.401-.959.413-.548.667-1.2.682-1.904.007-.337-.263-.599-.599-.599h-5.468c-.336 0-.606.262-.599.599.015.704.269 1.356.682 1.904.215.283.401.604.401.959v2.913L3.42 19.018A1.125 1.125 0 0 0 4.372 20.75h15.256a1.125 1.125 0 0 0 .952-1.732L14.25 9V6.087Z"/>',
    "adjustments-horizontal": '<path stroke-linecap="round" stroke-linejoin="round" d="M10.5 6h9.75M10.5 6a1.5 1.5 0 1 1-3 0m3 0a1.5 1.5 0 1 0-3 0M3.75 6H7.5m3 12h9.75m-9.75 0a1.5 1.5 0 0 1-3 0m3 0a1.5 1.5 0 0 0-3 0m-3.75 0H7.5m9-6h3.75m-3.75 0a1.5 1.5 0 0 1-3 0m3 0a1.5 1.5 0 0 0-3 0m-9.75 0h9.75"/>',
    "key": '<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 5.25a3 3 0 0 1 3 3m3 0a6 6 0 0 1-7.029 5.912c-.563-.097-1.159.026-1.563.43L10.5 17.25H8.25v2.25H6v2.25H2.25v-2.818c0-.597.237-1.17.659-1.591l6.499-6.499c.404-.404.527-1 .43-1.563A6 6 0 1 1 21.75 8.25Z"/>',
    "server": '<path stroke-linecap="round" stroke-linejoin="round" d="M21.75 17.25v-.228a4.5 4.5 0 0 0-.12-1.03l-2.268-9.64a3.375 3.375 0 0 0-3.285-2.602H7.923a3.375 3.375 0 0 0-3.285 2.602l-2.268 9.64a4.5 4.5 0 0 0-.12 1.03v.228m19.5 0a3 3 0 0 1-3 3H5.25a3 3 0 0 1-3-3m19.5 0a3 3 0 0 0-3-3H5.25a3 3 0 0 0-3 3m16.5 0h.008v.008h-.008v-.008Zm-3 0h.008v.008h-.008v-.008Z"/>',
    "cog-6-tooth": '<path stroke-linecap="round" stroke-linejoin="round" d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"/>',
  }

  const colorClasses = {
    "blue": "bg-blue-100 text-blue-700",
    "purple": "bg-purple-100 text-purple-700",
    "amber": "bg-amber-100 text-amber-700",
    "rose": "bg-rose-100 text-rose-700",
    "emerald": "bg-emerald-100 text-emerald-700",
    "sky": "bg-sky-100 text-sky-700",
    "orange": "bg-orange-100 text-orange-700",
    "indigo": "bg-indigo-100 text-indigo-700",
  }

  function getGoToItems() {
    let routerItems = []
    try {
      const data = modal?.getAttribute("data-routers")
      if (data) routerItems = JSON.parse(data)
    } catch {}
    return [...staticItems, ...routerItems]
  }

  const modal = document.getElementById("go-to-modal")
  const input = document.getElementById("go-to-input")
  const results = document.getElementById("go-to-results")
  const backdrop = document.getElementById("go-to-backdrop")
  const trigger = document.getElementById("go-to-trigger")
  let activeIndex = -1

  function openModal() {
    modal.classList.remove("hidden")
    input.value = ""
    renderItems(getGoToItems())
    activeIndex = -1
    setTimeout(() => input.focus(), 0)
  }

  function closeModal() {
    modal.classList.add("hidden")
    input.value = ""
    activeIndex = -1
  }

  function renderItems(items) {
    results.innerHTML = items.map((item, i) => {
      let iconHtml
      if (item.letter) {
        const cls = colorClasses[item.color] || "bg-accent/10 text-accent"
        iconHtml = `<span class="flex h-5 w-5 items-center justify-center rounded text-xs font-bold shrink-0 ${cls}">${item.letter}</span>`
      } else if (heroIcons[item.icon]) {
        iconHtml = `<span class="flex items-center justify-center size-5 text-base-content/40 shrink-0"><svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="size-4">${heroIcons[item.icon]}</svg></span>`
      } else {
        iconHtml = `<span class="size-5 shrink-0"></span>`
      }
      return `
        <li>
          <a href="${item.path}" data-index="${i}"
             class="go-to-item flex items-center gap-2.5 rounded-lg px-3 py-2 text-sm text-base-content/70 hover:bg-accent/10 hover:text-accent transition-colors">
            ${iconHtml}
            ${item.label}
          </a>
        </li>`
    }).join("")
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
    if (!q) { renderItems(getGoToItems()); return }
    const filtered = getGoToItems().filter(item =>
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

// Poll for new app versions and show refresh banner
function initVersionPolling() {
  const meta = document.querySelector("meta[name='app-version']")
  if (!meta) return

  const currentVersion = meta.getAttribute("content")
  if (!currentVersion) return

  // Poll every 30 seconds
  setInterval(() => {
    fetch("/api/version")
      .then(r => r.json())
      .then(data => {
        if (data.version && data.version !== currentVersion) {
          const banner = document.getElementById("version-banner")
          if (banner) banner.classList.remove("hidden")
        }
      })
      .catch(() => {})
  }, 30000)
}

// Start polling after page loads
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initVersionPolling)
} else {
  initVersionPolling()
}

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
