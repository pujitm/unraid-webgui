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
import topbar from "../vendor/topbar"
import CpuChartHook from "./cpu_chart_hook"
import ChartToggleHook from "./chart_toggle_hook"
import RichTableHook from "./rich_table_hook"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const Hooks = { CpuChart: CpuChartHook, ChartToggle: ChartToggleHook, RichTable: RichTableHook }
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

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

// The following enables data-on-<event> attributes to execute Phoenix.LiveView.JS
// on the element when the event is dispatched.
//
// This enables a generic pattern like <div class="text-error" data-on-action_failed={JS.show()}>
// where "action_failed" is the event name and JS.show() is the JS to execute.
//
// Notably, data-on-<event> does not allow arbitrary JS, only the Phoenix.LiveView.JS DSL.
const originalDispatchEvent = window.dispatchEvent.bind(window)
const dispatchErrorsSeen = new Set()

// Lifecycle note: this implementation dispatches after the original dispatch, rather than before it.
window.dispatchEvent = function (event) {
  const result = originalDispatchEvent(event)

  if (event.type.startsWith("phx:")) {
    const name = event.type.slice("phx:".length)

    // Skip events with colons - these are hook-specific events (e.g., rich-table:pulse)
    // that are handled by their respective hooks, not the generic data-on-* system
    if (name.includes(":")) {
      return result
    }

    try {
      document
        .querySelectorAll(`[data-on-${name}]`)
        .forEach((el) => {
          const js = el.getAttribute(`data-on-${name}`)
          if (!js) return

          // optional: gate on event.detail.id, etc.
          liveSocket.execJS(el, js)
        })
    } catch (error) {
      if (liveSocket.isDebugEnabled() && !dispatchErrorsSeen.has(name)) {
        console.debug(`Error executing JS for event ${name}`, event, error);
        dispatchErrorsSeen.add(name)
      }
    }
  }
  return result
}

