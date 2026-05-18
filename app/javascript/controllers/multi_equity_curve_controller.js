import { Controller } from "@hotwired/stimulus"
import Chart from "chart.js/auto"

// Phase 4.3 02_§4.5 反映: 複数 dataset 重ね描き(equity curve 比較画面用).
// 既存 equity_curve_controller.js と同じ import 方式(低-5 反映).
const COLORS = ["#2e7d32", "#1976d2", "#c62828", "#ef6c00", "#6a1b9a", "#00838f"]

export default class extends Controller {
  static values = {
    apiUrl: String,
    sampleSize: { type: Number, default: 1000 }
  }
  static targets = ["canvas"]

  async connect() {
    // multi-agent review followup(API compat 中-2): apiUrlValue が `?` を含むかで連結子を切替
    const sep = this.apiUrlValue.includes("?") ? "&" : "?"
    const url = `${this.apiUrlValue}${sep}sample_size=${this.sampleSizeValue}`
    const response = await fetch(url)
    const data = await response.json()
    this.renderChart(data.equity_curves || [])
  }

  renderChart(curves) {
    const allTs = new Set()
    curves.forEach(c => c.points.forEach(p => allTs.add(p.ts)))
    const labels = Array.from(allTs).sort()

    const datasets = curves.map((curve, idx) => {
      const tsMap = new Map(curve.points.map(p => [p.ts, parseFloat(p.equity)]))
      return {
        label: curve.label,
        data: labels.map(ts => tsMap.get(ts) ?? null),
        borderColor: COLORS[idx % COLORS.length],
        backgroundColor: COLORS[idx % COLORS.length] + "33",
        spanGaps: true,
        fill: false
      }
    })

    this.chart = new Chart(this.canvasTarget, {
      type: "line",
      data: { labels, datasets },
      options: {
        responsive: true,
        plugins: { legend: { display: true, position: "top" } },
        scales: { x: { ticks: { maxTicksLimit: 12 } } }
      }
    })
  }
}
