# Phase 2.1 console 動作確認スクリプト
#
# 用途: Domain::BacktestEngineService.new.run(...) の疎通検証 +
# timeout / メモリ実測。bin/rails runner で実行する。
#
# 使い方:
#   bin/rails runner script/phase2_1_console_check.rb [scenario]
#
# scenario:
#   minimal(default): 100 candles でエンジン疎通確認
#   1h_1month:        BTCUSDT 1H 足 1 ヶ月分(約 720 candles)
#   1h_1year:         BTCUSDT 1H 足 1 年分(約 8760 candles)
#   1m_1month:        BTCUSDT 1m 足 1 ヶ月分(約 43_200 candles)
#
# Bitget API は呼ばずダミー candle を生成して実測する。

require "bigdecimal"
require "benchmark"

scenario = ARGV.fetch(0, "minimal")

candle_count = case scenario
when "minimal"   then 100
when "1h_1month" then 720
when "1h_1year"  then 8760
when "1m_1month" then 43_200
else
  abort "Unknown scenario: #{scenario}"
end

puts "==> scenario=#{scenario}, candle_count=#{candle_count}"

# === fixture: Strategy::Definition + Strategy::Revision + Risk::Policy ===
definition = Strategy::Definition.find_or_create_by!(
  name: "phase2_1_check",
  market_type: "futures",
  status: "active"
)

# 空 on_tick の疎通用ダミー戦略(Domain::TradingScriptBase 継承)
script_body = <<~RUBY
  class Phase2_1Sample < Domain::TradingScriptBase
    def on_tick(ctx, candle)
      # No-op (疎通確認のみ)
    end
  end
RUBY

revision = definition.revisions.find_by(revision_number: 1) ||
           Strategy::Revision.create!(
             strategy_definition: definition,
             revision_number: 1,
             script_content: script_body,
             script_entrypoint: "Phase2_1Sample",
             status: "approved",
             ast_validation_status: "passed",
             uses_live_forbidden_input: false,
             ai_filter_enabled: false,
             ai_sizing_enabled: false
           )

risk_policy = Risk::Policy.find_or_create_by!(name: "phase2_1_check") do |p|
  p.max_drawdown_pct = BigDecimal("20")
  p.consecutive_loss_limit = 5
  p.max_position_exposure_usdt = BigDecimal("1000")
  p.max_leverage = 10
  p.cooldown_minutes = 30
  p.daily_loss_limit_usdt = BigDecimal("500")
end

# === ダミー candle 生成 ===
base_ts = Time.utc(2026, 1, 1, 0, 0, 0)
interval_seconds = scenario.start_with?("1h") ? 3_600 : 60

candles = (0...candle_count).map do |i|
  price = 40_000 + (Math.sin(i / 100.0) * 200) + (i * 0.01)
  {
    "ts" => base_ts + (i * interval_seconds),
    "open" => price.round(2).to_s,
    "high" => (price + 50).round(2).to_s,
    "low" => (price - 50).round(2).to_s,
    "close" => price.round(2).to_s,
    "base_volume" => "10",
    "quote_volume" => "400000"
  }
end

# === メモリ計測ヘルパー(macOS RSS in KB) ===
def rss_kb
  pid = Process.pid
  out = `ps -o rss= -p #{pid}`.strip
  out.to_i
end

before_rss = rss_kb
puts "==> before run RSS: #{before_rss} KB"

engine = Domain::BacktestEngineService.new

elapsed = Benchmark.realtime do
  result = engine.run(
    strategy_revision: revision,
    risk_policy: risk_policy,
    candles: candles,
    fee_rate: BigDecimal("0.001"),
    slippage_rate: BigDecimal("0.0005")
  )

  puts "==> result keys: #{result.keys.inspect}"
  puts "==> trades.size: #{result[:trades].size}"
  puts "==> equity_curve.size: #{result[:equity_curve].size}"
  puts "==> metrics.total_trades: #{result[:metrics].total_trades}"
  puts "==> metrics.win_rate: #{result[:metrics].win_rate}"
  puts "==> metrics.total_pnl: #{result[:metrics].total_pnl}"
end

after_rss = rss_kb
puts "==> after run RSS: #{after_rss} KB (delta: #{after_rss - before_rss} KB)"
puts "==> elapsed: #{elapsed.round(3)} sec"
puts "==> per candle: #{(elapsed * 1000.0 / candle_count).round(3)} ms"
