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

const SIDEBAR_COLLAPSED_KEY = "sidebar-collapsed"

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

window.addEventListener("phx:page-loading-start", _info => {
  pendingRequests++
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", _info => {
  pendingRequests = Math.max(0, pendingRequests - 1)
  if (pendingRequests === 0) {
    topbar.hide()
  }
  const saved = localStorage.getItem(SIDEBAR_COLLAPSED_KEY)
  if (saved === "true") applySidebarState(true)
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
  if (theme === "system") {
    const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches
    document.documentElement.setAttribute("data-theme", prefersDark ? "dark" : "light")
  } else {
    document.documentElement.setAttribute("data-theme", theme)
  }
})

document.addEventListener("DOMContentLoaded", () => {
  const saved = localStorage.getItem(SIDEBAR_COLLAPSED_KEY)
  if (saved === "true") applySidebarState(true)

  document.addEventListener("click", (e) => {
    const toggle = e.target.closest("#sidebar-toggle")
    if (!toggle) return

    const sidebar = document.getElementById("desktop-sidebar")
    const isCollapsed = sidebar?.getAttribute("data-collapsed") === "true"
    const newState = !isCollapsed
    applySidebarState(newState)
    localStorage.setItem(SIDEBAR_COLLAPSED_KEY, String(newState))
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

