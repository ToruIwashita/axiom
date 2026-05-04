import { Controller } from "@hotwired/stimulus"
import Chart from "chart.js/auto"

// 軽微 4 + Q-2C 反映:
// - apiUrl は View 側 url helper から data-* で受け取る(URL ハードコード排除)
// - sample_size はデフォルト 1000(View 側 data-* で上書き可能)
//   サーバー側で等間隔間引き → MAX_SAMPLE_SIZE=10_000 で clamp 済
//
// 02_§5.3 仕様準拠. completed 状態の Backtesting::Run 詳細画面で
// canvas data-equity-curve-target="canvas" にエクイティカーブを描画する.
export default class extends Controller {
  static values = {
    apiUrl: String,
    sampleSize: { type: Number, default: 1000 }
  }
  static targets = ["canvas"]

  async connect() {
    const url = `${this.apiUrlValue}?sample_size=${this.sampleSizeValue}`
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      if (!response.ok) return
      const data = await response.json()
      this.renderChart(data.points || [])
    } catch (e) {
      // 通信失敗時は描画しない(エラー表示は MVP では省略)
    }
  }

  disconnect() {
    if (this.chart) {
      this.chart.destroy()
      this.chart = null
    }
  }

  renderChart(points) {
    const labels = points.map((p) => p.ts)
    const equityData = points.map((p) => parseFloat(p.equity))

    this.chart = new Chart(this.canvasTarget, {
      type: "line",
      data: {
        labels: labels,
        datasets: [
          {
            label: "Equity",
            data: equityData,
            borderColor: "#2e7d32",
            backgroundColor: "rgba(46, 125, 50, 0.1)",
            borderWidth: 1.5,
            pointRadius: 0,
            fill: true,
            tension: 0.1
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        plugins: {
          legend: { display: true, position: "top" },
          tooltip: { mode: "index", intersect: false }
        },
        scales: {
          x: { display: true, ticks: { maxTicksLimit: 12 } },
          y: { display: true, beginAtZero: false }
        }
      }
    })
  }
}
