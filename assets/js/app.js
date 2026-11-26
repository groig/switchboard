// Switchboard client entry point (shared with a sibling Phoenix app).
//
// LiveView and CSS do the heavy lifting. This file only holds small, global
// glue that has no better home: theme and sidebar persistence, native <dialog>
// open/close, clipboard copy with a toast, time zone detection and view
// transitions on navigation. Feature hooks are colocated with their components.

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/switchboard"
import topbar from "../vendor/topbar"

const html = document.documentElement

// ---------------------------------------------------------------- Theme
// The initial theme is applied by the inline script in the root layout, before
// first paint. Here we only react to changes.

const THEME_KEY = "switchboard:theme"
const systemTheme = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"

const applyTheme = (pref) => {
  html.setAttribute("data-theme-switching", "")
  html.dataset.themePref = pref
  html.dataset.theme = pref === "system" ? systemTheme() : pref
  requestAnimationFrame(() => requestAnimationFrame(() => html.removeAttribute("data-theme-switching")))
}

const setTheme = (pref) => {
  if (!["system", "light", "dark"].includes(pref)) return
  try { localStorage.setItem(THEME_KEY, pref) } catch (_e) {}
  applyTheme(pref)
}

window.addEventListener("switchboard:set-theme", e => setTheme(e.detail?.theme || e.target?.dataset?.theme))
// From the server, after the profile's theme changes.
window.addEventListener("phx:set-theme", e => setTheme(e.detail?.theme))
window.addEventListener("storage", e => e.key === THEME_KEY && applyTheme(e.newValue || "system"))
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if ((html.dataset.themePref || "system") === "system") applyTheme("system")
})

// ------------------------------------------------------------- Sidebar

const SIDEBAR_KEY = "switchboard:sidebar"

window.addEventListener("switchboard:toggle-sidebar", () => {
  // Below the md breakpoint the sidebar is an off-canvas drawer instead.
  if (matchMedia("(max-width: 767px)").matches) {
    html.toggleAttribute("data-mobile-nav")
    return
  }
  const next = html.dataset.sidebar === "collapsed" ? "expanded" : "collapsed"
  html.dataset.sidebar = next
  try { localStorage.setItem(SIDEBAR_KEY, next) } catch (_e) {}
})

window.addEventListener("switchboard:close-mobile-nav", () => html.removeAttribute("data-mobile-nav"))

// ------------------------------------------------------------- Dialogs
// <.dialog> and <.sheet> render a native <dialog>. JS.dispatch opens/closes it;
// a `data-on-close` JS command (if any) runs whenever it closes, whatever the
// cause (Esc, backdrop click, close button).

window.addEventListener("switchboard:dialog-open", e => {
  const dialog = e.target
  if (dialog instanceof HTMLDialogElement && !dialog.open) dialog.showModal()
})

window.addEventListener("switchboard:dialog-close", e => {
  const dialog = e.target.closest("dialog") || e.target
  if (dialog instanceof HTMLDialogElement && dialog.open) dialog.close()
})

document.addEventListener("close", e => {
  const dialog = e.target
  if (dialog instanceof HTMLDialogElement && dialog.dataset.onClose) {
    liveSocket.execJS(dialog, dialog.dataset.onClose)
  }
}, true)

// The dialog's content fills it edge to edge, so a click whose target is the
// <dialog> itself can only be on the backdrop: close it.
document.addEventListener("click", e => {
  const dialog = e.target
  if (dialog instanceof HTMLDialogElement && dialog.open && dialog.classList.contains("ui-dialog")) {
    dialog.close()
  }
})

// Select an input's text (e.g. inline rename): JS.dispatch("switchboard:select").
window.addEventListener("switchboard:select", e => e.target.select?.())

// ------------------------------------------------- Clipboard and toasts

const toast = (message, kind = "info") => {
  const region = document.getElementById("client-toasts")
  const template = document.getElementById("toast-template")
  if (!region || !template) return
  const node = template.content.firstElementChild.cloneNode(true)
  node.dataset.kind = kind
  node.querySelector("[data-toast-message]").textContent = message
  region.appendChild(node)
  const dismiss = () => {
    node.style.opacity = "0"
    node.style.transform = "translateY(4px) scale(0.98)"
    setTimeout(() => node.remove(), 200)
  }
  node.querySelector("[data-toast-close]")?.addEventListener("click", dismiss)
  setTimeout(dismiss, 3200)
}

window.addEventListener("switchboard:toast", e => toast(e.detail?.message, e.detail?.kind))
// From the server (push_event "toast"), e.g. a new notification.
window.addEventListener("phx:toast", e => toast(e.detail?.message, e.detail?.kind || "info"))

// JS.dispatch("switchboard:copy", detail: %{text: "..."}) or data-copy on the target.
window.addEventListener("switchboard:copy", async e => {
  const el = e.target
  const text = e.detail?.text ?? el.dataset.copy ?? el.value ?? el.textContent
  try {
    await navigator.clipboard.writeText(text)
    toast(el.dataset.copiedMessage || e.detail?.message || "Copied")
  } catch (_err) {
    toast(e.detail?.failed || el.dataset.copyFailedMessage || "Couldn't copy", "error")
  }
})

// ------------------------------------------------------------ Time zone
// Sent on connect (LiveView) and kept in a cookie (plain requests), so dates
// render in the viewer's zone. A profile setting overrides it server-side.

const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone
document.cookie = `tz=${encodeURIComponent(timezone)}; path=/; max-age=31536000; samesite=lax`

// ----------------------------------------------------------- LiveSocket

let navigating = false

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken, timezone},
  hooks: {...colocatedHooks},
  dom: {
    // Smooth cross-fade on live navigation only; regular patches stay instant.
    onDocumentPatch(start) {
      if (navigating && document.startViewTransition &&
          !matchMedia("(prefers-reduced-motion: reduce)").matches) {
        navigating = false
        document.startViewTransition(start)
      } else {
        start()
      }
    },
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "oklch(52% 0.17 268)"}, shadowColor: "transparent", barThickness: 2})
window.addEventListener("phx:page-loading-start", info => {
  if (["redirect", "patch"].includes(info.detail?.kind)) navigating = true
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", _info => {
  topbar.hide()
  html.removeAttribute("data-mobile-nav")
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

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
    window.addEventListener("keyup", _e => keyDown = null)
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
