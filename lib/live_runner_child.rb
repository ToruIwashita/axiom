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
# エラー JSON 整形 を全てインライン定義する(B 案 / 完全不変保護方針).
#
# Phase 2 引き継ぎ #15(lib/runner_child_common.rb 抽出判断)は Step 3.3-6 で対応予定.
# 本 Step では backtest_runner_child.rb と同形式で重複維持し, 共通化判断は次 Step で実施する.
#
# ## 主要差分(backtest_runner_child.rb との比較)
# - Domain::LiveContext を使用(Domain::BacktestContext ではない)
# - callback は on_start / on_tick / on_order_event / on_stop の 4 種類サポート
# - state diff は backtest と同等(replace_all op)/ 設計書 05_§2.7

require "json"
require "digest"
require "bigdecimal"
require "ostruct"

SCHEMA_VERSION = "1.0"
DEFAULT_CPU_SECONDS = 1
DEFAULT_MEMORY_BYTES = 256 * 1024 * 1024

# === setrlimit インライン適用 ===
# macOS / Darwin では RLIMIT_AS が EINVAL で拒否されるため rescue で守る.
begin
  Process.setrlimit(Process::RLIMIT_CPU, DEFAULT_CPU_SECONDS) if defined?(Process::RLIMIT_CPU)
rescue Errno::EINVAL
  # macOS 開発時のフォールバック
end

begin
  Process.setrlimit(Process::RLIMIT_AS, DEFAULT_MEMORY_BYTES) if defined?(Process::RLIMIT_AS)
rescue Errno::EINVAL
  # macOS は RLIMIT_AS の精密な enforcement 不可
end

def emit_error_response(callback_name, error_class:, message:, backtrace: nil)
  error_entry = { "class" => error_class, "message" => message }
  error_entry["backtrace"] = backtrace if backtrace
  payload = {
    "schema_version" => SCHEMA_VERSION,
    "callback" => callback_name,
    "status" => "error",
    "order_intents" => [],
    "logs" => [],
    "errors" => [ error_entry ],
    "strategy_state_diff" => { "ops" => [] }
  }
  $stdout.puts(payload.to_json)
end

# === stdin から JSON 受信 ===
raw_input = $stdin.read
begin
  input = JSON.parse(raw_input)
rescue JSON::ParserError => e
  emit_error_response(nil, error_class: "JsonParseError", message: e.message)
  exit 0
end

callback_name = input["callback"]

# === script_checksum 照合 ===
computed_checksum = Digest::SHA256.hexdigest(input["script_content"])
unless computed_checksum == input["script_checksum"]
  emit_error_response(callback_name, error_class: "ScriptIntegrityError", message: "checksum mismatch")
  exit 0
end

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
