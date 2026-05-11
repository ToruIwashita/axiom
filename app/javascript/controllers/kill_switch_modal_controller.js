import { Controller } from "@hotwired/stimulus"

// Phase 3.4b Step 3.4-13 / 02_§6.2.3.3
//
// kill-switch モード選択モーダルの開閉制御.
// 現状の _kill_switch_modal.html.erb は <details>/<summary> ベースで JS なしでも動作するが,
// 本 controller は誤操作防止のため以下の機能を追加する:
// - submit 時に二重送信防止(disabled 切替)
// - モーダル外クリックで閉じる
//
// data-controller="kill-switch-modal" は partial 側で付与済.
export default class extends Controller {
  static values = {
    sessionId: Number
  }

  connect() {
    this.closeOnOutsideClick = this.closeOnOutsideClick.bind(this)
    document.addEventListener("click", this.closeOnOutsideClick)

    this.element.addEventListener("submit", this.disableSubmits.bind(this))
  }

  disconnect() {
    document.removeEventListener("click", this.closeOnOutsideClick)
  }

  // モーダル(<details>)外側クリックで自動的に閉じる(誤操作防止).
  closeOnOutsideClick(event) {
    if (this.element.open && !this.element.contains(event.target)) {
      this.element.open = false
    }
  }

  // submit 中の二重送信を抑止する.
  disableSubmits() {
    const submits = this.element.querySelectorAll('input[type="submit"], button[type="submit"]')
    submits.forEach((btn) => {
      btn.disabled = true
    })
  }
}
