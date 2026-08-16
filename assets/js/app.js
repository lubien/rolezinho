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
import {hooks as colocatedHooks} from "phoenix-colocated/rolezinho"
import topbar from "../vendor/topbar"

const ViewTransitionHook = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault();

      const $parentOrSelf = this.el.dataset.parentId
        ? this.el.closest(`#${this.el.dataset.parentId}`)
        : this.el;

      if ($parentOrSelf) {
        $parentOrSelf.classList.add("navigating");

        if ($parentOrSelf.dataset.transitionName) {
          startViewTransition({ target: $parentOrSelf });
        }
        for (const child of $parentOrSelf.querySelectorAll(
          "[data-transition-name]",
        )) {
          child.classList.add("navigating");
          startViewTransition({ target: child });
        }
      } else {
        console.error("No parent or self found for transition", this.el);
      }

      liveSocket.js().navigate(this.el.href);
    });
  },
};

let transitionTypes = [];
let transitionEls = [];
let scheduleTransition = null;

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: { ...colocatedHooks, ViewTransitionHook },
  dom: {
    onDocumentPatch(start) {
      const update = () => {
        // reset transitionEls
        transitionEls.forEach((el) => (el.style.viewTransitionName = ""));
        transitionEls = [];
        transitionTypes = [];
        scheduleTransition = null;
        start();
      };
      const supportsViewTransitions =
        typeof document.startViewTransition === "function";
      if (
        supportsViewTransitions &&
        (transitionEls.length !== 0 || scheduleTransition)
      ) {
        // firefox 144 doesn't support the callbackOptions yet, so fallback to the basic version.
        try {
          document.startViewTransition({
            // tsc somehow doesn't know about the `update` param??!
            // @ts-expect-error
            update,
            types: transitionTypes.length ? transitionTypes : ["same-document"],
          });
        } catch (error) {
          document.startViewTransition(update);
        }
      } else {
        update();
      }
    },
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

function startViewTransition(e) {
  const target = e.target;
  const opts = e.detail || {};
  const transition_name =
    opts.transition_name ||
    (target && target.dataset && target.dataset.transitionName);
  if (target && target.style && transition_name && target !== window) {
    target.style.viewTransitionName = transition_name;
    transitionEls.push(e.target);
  }
  if (opts.type) {
    transitionTypes.push(opts.type);
  }
  scheduleTransition = true;
}

window.addEventListener("phx:start-view-transition", startViewTransition);

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
