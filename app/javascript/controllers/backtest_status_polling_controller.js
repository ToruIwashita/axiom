import { Controller } from "@hotwired/stimulus"

// 軽微 4 + 軽微 5 反映:
// - apiUrl は View 側 url helper から data-* で受け取る(URL ハードコード排除)
// - Turbo Streams broadcast の fallback として動作(Action Cable 切断時の保険)
//
// Phase 2.3 Step 3-6 で導入. status が pending / running の間は intervalMs ごとに
// Run の status を JSON API から取得し,terminal 状態に遷移したら window.location.reload
// で結果画面を再描画する.
export default class extends Controller {
  static values = {
    apiUrl: String,
    status: String,
    intervalMs: { type: Number, default: 3000 }
  }

  connect() {
    if (["pending", "running"].includes(this.statusValue)) {
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
      const run = await response.json()
      if (!["pending", "running"].includes(run.status)) {
        window.location.reload()
      }
    } catch (e) {
      // 通信失敗時は次回 interval で再試行
    }
  }
}
