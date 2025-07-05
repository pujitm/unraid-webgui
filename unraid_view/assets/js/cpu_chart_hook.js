export default {
  mounted() {
    this.windowSize = parseInt(this.el.dataset.window) || 60
    this.dataPoints = JSON.parse(this.el.dataset.history) || []

    // Prepare labels (simple empty labels per point)
    const labels = this.dataPoints.map(() => "")

    const ctx = this.el.querySelector("canvas").getContext("2d")
    this.chart = new window.Chart(ctx, {
      type: "line",
      data: {
        labels: labels,
        datasets: [
          {
            label: "CPU %",
            data: this.dataPoints,
            borderColor: "#2563eb", // Tailwind primary (blue-600)
            backgroundColor: "rgba(37, 99, 235, 0.2)",
            borderWidth: 2,
            pointRadius: 0,
            tension: 0.3,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        scales: {
          y: {
            min: 0,
            max: 100,
            ticks: {
              stepSize: 20,
            },
          },
          x: {
            display: false, // hide x labels for compact view
          },
        },
        plugins: {
          legend: {
            display: false,
          },
        },
      },
    })

    this.handleEvent("cpu_usage_tick", ({ value }) => {
      this.appendPoint(value)
    })

    this.handleEvent("window_change", ({ window }) => {
      this.windowSize = window
      this.trimData()
      this.updateChart()
    })
  },

  appendPoint(value) {
    this.dataPoints.push(value)
    if (this.dataPoints.length > this.windowSize) {
      this.dataPoints.shift()
    }
    this.updateChart()
  },

  trimData() {
    if (this.dataPoints.length > this.windowSize) {
      this.dataPoints = this.dataPoints.slice(this.dataPoints.length - this.windowSize)
    }
  },

  updateChart() {
    this.chart.data.labels = this.dataPoints.map(() => "")
    this.chart.data.datasets[0].data = this.dataPoints
    this.chart.update("none")
  },
} 