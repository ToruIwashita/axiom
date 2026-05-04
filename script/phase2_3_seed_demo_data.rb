# Phase 2.3 ブラウザ E2E 疎通用デモデータ投入スクリプト
#
# 用途: bin/rails s + bundle exec sidekiq 起動後にブラウザで完成動作を
# 確認するためのデータ投入を一括実施する.
#
# 使い方:
#   bin/rails runner script/phase2_3_seed_demo_data.rb
#   → http://localhost:3000/ で「バックテスト一覧」確認
#
# 投入するデータ(idempotent: 再実行可能):
# - Strategy::Definition "Demo Strategy"(active)
# - Strategy::Revision #1(approved + ast_passed + ダミー on_tick)
# - Risk::Policy "Demo Policy"
# - Backtesting::Run(completed)+ Metrics + Trades 3 件 + EquityCurvePoint 50 件
#
# 03_§Step 3-9 + 軽微 5(Action Cable WebSocket)+ Q-2B(broadcast)
# + Q-2C(EquityCurve sampling)+ Chart.js 描画 を実機検証する基盤データ.

require "bigdecimal"

definition = Strategy::Definition.find_or_create_by!(
  name: "Demo Strategy",
  market_type: "futures",
  status: "active"
) do |d|
  d.description = "Phase 2 完了判定用のダミー戦略"
end
puts "==> Strategy::Definition ##{definition.id} (#{definition.name})"

script_body = <<~RUBY
  class DemoStrategy < Domain::TradingScriptBase
    def on_tick(ctx, candle)
      # No-op (Phase 2 完了判定用、実際の発注はしない)
    end
  end
RUBY

revision = definition.revisions.find_by(revision_number: 1) || Strategy::Revision.create!(
  strategy_definition: definition,
  revision_number: 1,
  script_content: script_body,
  script_entrypoint: "DemoStrategy",
  status: "approved",
  ast_validation_status: "passed",
  uses_live_forbidden_input: false,
  ai_filter_enabled: false,
  ai_sizing_enabled: false,
  approved_at: Time.current
)
puts "==> Strategy::Revision ##{revision.revision_number} (#{revision.status})"

risk_policy = Risk::Policy.find_or_create_by!(name: "Demo Policy") do |p|
  p.max_drawdown_pct = BigDecimal("20")
  p.consecutive_loss_limit = 5
  p.max_position_exposure_usdt = BigDecimal("1000")
  p.max_leverage = 10
  p.cooldown_minutes = 30
  p.daily_loss_limit_usdt = BigDecimal("500")
end
puts "==> Risk::Policy ##{risk_policy.id} (#{risk_policy.name})"

# 既に Demo Run があれば削除して再投入(metrics/trades/equity_curve も dependent: :destroy で連動)
Backtesting::Run.where(strategy_definition: definition).destroy_all

run = Backtesting::Run.new(
  strategy_definition: definition,
  strategy_revision: revision,
  risk_policy: risk_policy,
  symbol: "BTCUSDT",
  granularity: "1H",
  period_from: Time.utc(2026, 1, 1),
  period_to: Time.utc(2026, 1, 31),
  fee_rate: BigDecimal("0.001"),
  slippage_rate: BigDecimal("0.0005"),
  status: "pending"
)
run.save!
run.start!(started_at: Time.utc(2026, 4, 1))

# Trades 3 件投入
[
  { side: "long",  pnl: 250 },
  { side: "short", pnl: -100 },
  { side: "long",  pnl: 350 }
].each_with_index do |t, i|
  Backtesting::Trade.create!(
    run: run,
    side: t[:side],
    entry_at: Time.utc(2026, 1, 5 + i),
    exit_at: Time.utc(2026, 1, 5 + i, 4),
    entry_price: BigDecimal("40000"),
    exit_price: BigDecimal("40000") + BigDecimal(t[:pnl] * 10),
    quantity: BigDecimal("0.5"),
    pnl: BigDecimal(t[:pnl])
  )
end

# Metrics 投入
Backtesting::Metrics.create!(
  run: run,
  win_rate: BigDecimal("0.667"),
  total_pnl: BigDecimal("500"),
  max_drawdown: BigDecimal("0.05"),
  sharpe_ratio: BigDecimal("1.25"),
  sortino_ratio: BigDecimal("1.85"),
  volatility: BigDecimal("0.12"),
  profit_factor: BigDecimal("6.0"),
  total_trades: 3,
  avg_holding_seconds: 14_400
)

# EquityCurvePoint 50 件投入(振動付き)
50.times do |i|
  Backtesting::EquityCurvePoint.create!(
    run: run,
    ts: Time.utc(2026, 1, 1) + (i * 14_400),  # 4 時間ごと
    equity: BigDecimal(10_000) + BigDecimal((Math.sin(i / 5.0) * 200 + i * 10).round(2).to_s),
    drawdown: BigDecimal((rand * 0.05).round(4).to_s),
    position_size: BigDecimal("0")
  )
end

run.complete!(finished_at: Time.utc(2026, 4, 1, 0, 30))

puts "==> Backtesting::Run ##{run.id} (#{run.status}) created with metrics + 3 trades + 50 equity_curve_points"
puts ""
puts "ブラウザ確認手順:"
puts "  1. bin/rails s で Rails サーバー起動"
puts "  2. http://localhost:3000/ を開く(root → /backtesting_runs)"
puts "  3. 「Demo Strategy」の Run 詳細 → エクイティカーブ + Metrics + Trades 表示確認"
puts "  4. /strategy_definitions → Demo Strategy 詳細 → Revision #1 → 承認済確認"
puts "  5. (任意)Sidekiq 起動 + 新規バックテスト実行 → Turbo Streams で status 自動更新確認"
puts "  6. (任意)DevTools Network → /cable WebSocket(101 Switching Protocols)接続確認(軽微 5)"
