# Phase 3.4b ライブトレード Demo E2E 動作確認用デモデータ投入スクリプト
#
# 用途: Bitget demo 環境を使ったライブトレード E2E 検証
# (promote → 起動 → シグナル → エントリー → 約定 → クローズ → 停止 全 8 ステップ)
# のための定義 / 戦略リビジョン / Risk Policy を一括投入する.
#
# 前提:
#   - `bin/rails credentials:edit` で `bitget.api_key/secret_key/passphrase` 設定済
#   - Bitget demo 環境(USDT-M perpetual)で動作確認すること
#
# 使い方:
#   bin/rails runner script/phase3_4b_seed_demo_data.rb
#   → http://localhost:3000/strategy_definitions で「Demo Live Strategy」確認
#   → Revision #1 を promote → /live_trading_sessions/new で起動
#
# 投入するデータ(idempotent: 再実行可能):
# - Strategy::Definition "Demo Live Strategy"(futures / active)
# - Strategy::Revision #1(approved + ast_passed / promote 操作で promoted に遷移)
# - Risk::Policy "Demo Live Policy"(最小エクスポージャ + 安全マージン)
#
# 戦略ロジック:
#   - RSI(14) < 30 でロングエントリー / > 70 でショートエントリー
#   - 反対側シグナルでクローズ
#   - サイズ 0.001 BTC 固定(Bitget BTCUSDT 最小ロット相当)

require "bigdecimal"

definition = Strategy::Definition.find_or_create_by!(
  name: "Demo Live Strategy",
  market_type: "futures",
  status: "active"
) do |d|
  d.description = "Phase 3.4b ライブトレード E2E 検証用デモ戦略(RSI 14 ベース)"
end
puts "==> Strategy::Definition ##{definition.id} (#{definition.name})"

script_body = <<~RUBY
  class DemoLiveStrategy < Domain::TradingScriptBase
    def on_tick(ctx, _candle)
      rsi = ctx.rsi(14)
      return if rsi.nil?

      if ctx.position.size.zero?
        if rsi < 30
          ctx.order.entry(side: :long, size: 0.001, order_type: :market,
                          tp_pct: 0.005, sl_pct: 0.003)
        elsif rsi > 70
          ctx.order.entry(side: :short, size: 0.001, order_type: :market,
                          tp_pct: 0.005, sl_pct: 0.003)
        end
      else
        should_close = (ctx.position.side == :long && rsi > 70) ||
                       (ctx.position.side == :short && rsi < 30)
        ctx.order.close if should_close
      end
    end
  end
RUBY

revision = definition.revisions.find_by(revision_number: 1) || Strategy::Revision.create!(
  strategy_definition: definition,
  revision_number: 1,
  script_content: script_body,
  script_entrypoint: "DemoLiveStrategy",
  status: "approved",
  ast_validation_status: "passed",
  uses_live_forbidden_input: false,
  ai_filter_enabled: false,
  ai_sizing_enabled: false,
  approved_at: Time.current
)
puts "==> Strategy::Revision ##{revision.revision_number} (#{revision.status})"

risk_policy = Risk::Policy.find_or_create_by!(name: "Demo Live Policy") do |p|
  p.max_drawdown_pct = BigDecimal("20")
  p.consecutive_loss_limit = 3
  p.max_position_exposure_usdt = BigDecimal("100")
  p.max_leverage = 5
  p.cooldown_minutes = 5
  p.daily_loss_limit_usdt = BigDecimal("50")
end
puts "==> Risk::Policy ##{risk_policy.id} (#{risk_policy.name})"

puts ""
puts "次の手順で Demo E2E を実行:"
puts "  1. credentials 設定確認: bin/rails credentials:show | grep -A3 bitget"
puts "  2. サーバー起動: bin/rails s + bundle exec sidekiq"
puts "  3. ブラウザで以下を順に操作:"
puts "     a. http://localhost:3000/strategy_definitions"
puts "        → Demo Live Strategy → Revision #1 → 「promote」ボタン"
puts "     b. http://localhost:3000/live_trading_sessions/new"
puts "        → Definition: Demo Live Strategy / Revision: #1 / Policy: Demo Live Policy"
puts "        → Symbol: BTCUSDT / Leverage: 5 / Margin Mode: isolated"
puts "        → Position Mode: one_way_mode / Asset Mode: single / Margin Coin: USDT"
puts "        → Emergency Stop Mode: cancel_only → 「起動」"
puts "     c. /live_trading_sessions/:id で status が starting → running に遷移確認"
puts "     d. DevTools Console で JS error なしを確認(JS UI チェックリスト 3 番)"
puts "     e. シグナル発生待機(RSI<30 or >70 で自動エントリー)"
puts "     f. 約定確認 → Trade 一覧 → 詳細"
puts "     g. kill-switch 3 モード検証(別 session を起動して各モード実行):"
puts "        - cancel_only: 全注文 cancel + position 保持"
puts "        - cancel_and_market_close: 全注文 cancel + close_positions"
puts "        - cancel_and_reduce_only: reduce_only 追従ループ + fallback close"
puts "     h. emergency_stop: 全 running session 一括停止"
puts "  4. 観察ポイント:"
puts "     - Turbo Streams: status 変化が画面に即時反映"
puts "     - Action Cable: DevTools Network → /cable WebSocket(101)接続"
puts "     - reconciliation: bootstrap 13 step 完了ログ確認"
puts "     - sanitize: log に api_key/secret/passphrase が出ていない"
