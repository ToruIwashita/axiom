#!/usr/bin/env ruby
# frozen_string_literal: true

# バックテスト用戦略実行子プロセスのエントリポイント.
#
# 親プロセス(`Domain::BacktestEngineService` 経由の `Infrastructure::StrategyRunnerChildSpawner`)
# から `Open3.popen3 ruby lib/backtest_runner_child.rb` で別 Ruby インタプリタとして起動される.
# Rails 環境を継承せず, JSON / Digest / BigDecimal / OStruct の Ruby 標準ライブラリのみ
# require する.
#
# 重要1 対応(02_§0.4): Phase 1.2 既実装 `lib/strategy_runner_child.rb` と同設計方針.
# Infrastructure::* 名前空間は一切参照せず, setrlimit / checksum 検証 /
# エラー JSON 整形 は `lib/runner_child_common.rb` で共通化している
# (Phase 2 引き継ぎ #15 / Step 3.3-6).
#
# 重要3 対応(02_§0.4): ctx.state 全体置換方式(案 Z). 戦略コードによる
# `ctx.state[:key] = value` の変更を `strategy_state_diff: { "ops" => [{
# "op" => "replace_all", "value" => ctx.state }] }` で親プロセスへ返却する.

require_relative "runner_child_common"
require "bigdecimal"
require "ostruct"

input = load_and_verify_input!
callback_name = input["callback"]

# === Domain クラス群 個別読込(zeitwerk なし環境, Rails 非依存) ===
# Domain::BacktestContext / VO 群は Rails 機能を使わない実装(BigDecimal は標準ライブラリ).
trading_script_base_path = File.expand_path("../app/domain/trading_script_base", __dir__)
position_value_object_path = File.expand_path("../app/domain/position_value_object", __dir__)
order_intent_value_object_path = File.expand_path("../app/domain/order_intent_value_object", __dir__)
backtest_context_path = File.expand_path("../app/domain/backtest_context", __dir__)

require trading_script_base_path
require position_value_object_path
require order_intent_value_object_path
require backtest_context_path

# === eval + callback 実行 ===
# TOPLEVEL_BINDING を明示することで戦略 class を Object 直下の定数として登録する
# (eval をトップレベルで呼んでも begin/rescue ブロック内のローカルスコープになるため).
begin
  TOPLEVEL_BINDING.eval(input["script_content"]) # rubocop:disable Security/Eval
  strategy_class = Object.const_get(input["script_entrypoint"])
  strategy = strategy_class.new

  ctx_input = input["ctx_input"] || {}
  ctx = Domain::BacktestContext.from_ctx_input(ctx_input)

  case callback_name
  when "on_tick"
    strategy.on_tick(ctx, ctx.candle)
  else
    raise ArgumentError, "Unknown callback: #{callback_name.inspect}"
  end

  # 重要 3 対応(案 Z): ctx.state 全体置換方式.
  # 戦略コードによる ctx.state[:key] = value の変更を state 全体として親プロセスへ返却.
  # 差分計算は Phase 3 で再判断.
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
