import { Controller } from "@hotwired/stimulus"
import Chart from "chart.js/auto"

// Phase 4.3 02_§4.5 反映: dashboard 累積 PnL 棒グラフ.
// 既存 equity_curve_controller.js と同じ import 方式(低-5 反映).
export default class extends Controller {
  static values = { apiUrl: String }
  static targets = ["canvas"]

  async connect() {
    const response = await fetch(this.apiUrlValue)
    const data = await response.json()
    this.renderChart(data)
  }

  renderChart(data) {
    const pnl = data.cumulative_pnl
    this.chart = new Chart(this.canvasTarget, {
      type: "bar",
      data: {
        labels: ["backtesting", "live_trading"],
        datasets: [{
          label: "累積 PnL(直近 30 日)",
          data: [parseFloat(pnl.backtesting), parseFloat(pnl.live_trading)],
          backgroundColor: ["#1976d2", "#2e7d32"]
        }]
      },
      options: {
        responsive: true,
        plugins: { legend: { display: true, position: "top" } }
      }
    })
  }
}
