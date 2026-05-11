import { Controller } from "@hotwired/stimulus"

// Phase 3.4b Step 3.4-13 / 02_§6.2.4
//
// 軽微 4 + 軽微 5 同等の polling fallback:
// - apiUrl は View 側 url helper から data-* で受け取る(URL ハードコード排除)
// - Turbo Streams broadcast の fallback として動作(Action Cable 切断時の保険)
//
// status が非 terminal(starting / reconciling / running / cooling_down / stopping)の
// 間は intervalMs ごとに Session の status を JSON API から取得し,terminal 状態に
// 遷移したら window.location.reload で結果画面を再描画する.
export default class extends Controller {
  static values = {
    apiUrl: String,
    status: String,
    intervalMs: { type: Number, default: 3000 }
  }

  static TERMINAL_STATUSES = ["stopped", "failed_to_start", "halted"]

  connect() {
    if (!this.constructor.TERMINAL_STATUSES.includes(this.statusValue)) {
      this.timer = setInterval(() => this.poll(), this.intervalMsValue)
    }
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  async poll() {
    try {
      const response = await fetch(this.apiUrlValue, { headers: { Accept: "application/json" } })
      if (!response.ok) return
      const session = await response.json()
      if (this.constructor.TERMINAL_STATUSES.includes(session.status)) {
        window.location.reload()
      } else if (session.status !== this.statusValue) {
        // 非 terminal でも status 変化があれば再描画(starting → running 等)
        window.location.reload()
      }
    } catch (e) {
      // 通信失敗時は次回 interval で再試行
    }
  }
}
