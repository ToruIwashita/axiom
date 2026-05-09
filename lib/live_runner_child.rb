#!/usr/bin/env ruby
# frozen_string_literal: true

# ライブトレード用戦略実行子プロセスのエントリポイント.
#
# 親プロセス(Phase 3.3 後続 Step の `LiveTradingWorker` / `Domain::LiveTradingProcessManager`
# 経由の `Infrastructure::StrategyRunnerChildSpawner` 相当)から `Open3.popen3 ruby
# lib/live_runner_child.rb` で別 Ruby インタプリタとして起動される.
# Rails 環境を継承せず, JSON / Digest / BigDecimal / OStruct の Ruby 標準ライブラリのみ
# require する.
#
# Phase 1.2(`lib/strategy_runner_child.rb`)/ Phase 2.1(`lib/backtest_runner_child.rb`)
# 構造踏襲: Infrastructure::* 名前空間は一切参照せず, setrlimit / checksum 検証 /
# エラー JSON 整形 は `lib/runner_child_common.rb` で共通化している
# (Phase 2 引き継ぎ #15 / Step 3.3-6 / B 案 / 完全不変保護方針).
#
# ## 主要差分(backtest_runner_child.rb との比較)
# - Domain::LiveContext を使用(Domain::BacktestContext ではない)
# - callback は on_start / on_tick / on_order_event / on_stop の 4 種類サポート
# - state diff は backtest と同等(replace_all op)/ 設計書 05_§2.7

require_relative "runner_child_common"
require "bigdecimal"
require "ostruct"

input = load_and_verify_input!
callback_name = input["callback"]

# === Domain クラス群 個別読込(zeitwerk なし環境, Rails 非依存) ===
trading_script_base_path = File.expand_path("../app/domain/trading_script_base", __dir__)
position_value_object_path = File.expand_path("../app/domain/position_value_object", __dir__)
order_intent_value_object_path = File.expand_path("../app/domain/order_intent_value_object", __dir__)
live_context_path = File.expand_path("../app/domain/live_context", __dir__)

require trading_script_base_path
require position_value_object_path
require order_intent_value_object_path
require live_context_path

# === eval + callback 実行 ===
begin
  TOPLEVEL_BINDING.eval(input["script_content"]) # rubocop:disable Security/Eval
  strategy_class = Object.const_get(input["script_entrypoint"])
  strategy = strategy_class.new

  ctx_input = input["ctx_input"] || {}
  ctx = Domain::LiveContext.from_ctx_input(ctx_input)

  case callback_name
  when "on_start"
    strategy.on_start(ctx)
  when "on_tick"
    strategy.on_tick(ctx, ctx.candle)
  when "on_order_event"
    event = input["event"] || {}
    strategy.on_order_event(ctx, event)
  when "on_stop"
    strategy.on_stop(ctx)
  else
    raise ArgumentError, "Unknown callback: #{callback_name.inspect}"
  end

  $stdout.puts({
    "schema_version" => SCHEMA_VERSION,
    "callback" => callback_name,
    "status" => "ok",
    "order_intents" => ctx.order_intents,
    "logs" => [],
    "errors" => [],
    "strategy_state_diff" => { "ops" => [ { "op" => "replace_all", "value" => ctx.state } ] }
  }.to_json)
rescue => e # rubocop:disable Style/RescueStandardError
  emit_error_response(callback_name, error_class: e.class.name, message: e.message, backtrace: e.backtrace&.first(10))
  exit 0
end
