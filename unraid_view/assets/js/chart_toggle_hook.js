export default {
  mounted() {
    this.containerId = this.el.dataset.containerId || "cpu-chart-container"
    this.container = document.getElementById(this.containerId)
    this.show = this.el.dataset.initialShow === "true"
    this.updateUI()

    this.debounceMs = 300
    this.timer = null

    // Listen for button clicks to toggle and push event to server
    this.el.addEventListener("click", () => {
      this.show = !this.show
      this.updateUI()
      clearTimeout(this.timer)
      this.timer = setTimeout(() => {
        this.pushEvent("set_show_chart", {show: this.show})
      }, this.debounceMs)
    })

    // Register listener for server-pushed events
    this.handleEvent("chart_toggle", ({show}) => {
      console.log("ChartToggleHook received push_event", show)
      if (typeof show === "boolean") {
        this.show = show
        this.updateUI()
      }
    })
  },

  updateUI() {
    if (this.container) {
      this.container.style.display = this.show ? "block" : "none"
    }
    this.el.textContent = this.show ? "Hide Chart" : "Show Chart"
  },
} 