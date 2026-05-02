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
# エラー JSON 整形 を全てインライン定義する.
#
# 重要3 対応(02_§0.4): ctx.state 全体置換方式(案 Z). 戦略コードによる
# `ctx.state[:key] = value` の変更を `strategy_state_diff: { "ops" => [{
# "op" => "replace_all", "value" => ctx.state }] }` で親プロセスへ返却する.

require "json"
require "digest"
require "bigdecimal"
require "ostruct"

SCHEMA_VERSION = "1.0"
DEFAULT_CPU_SECONDS = 1
DEFAULT_MEMORY_BYTES = 256 * 1024 * 1024

# === setrlimit インライン適用 ===
# macOS / Darwin では RLIMIT_AS が EINVAL で拒否されるため rescue で守る.
# Linux 本番では setrlimit が確実に効く前提で運用する.
begin
  Process.setrlimit(Process::RLIMIT_CPU, DEFAULT_CPU_SECONDS) if defined?(Process::RLIMIT_CPU)
rescue Errno::EINVAL
  # macOS 開発時のフォールバック(本番 Linux では発生しない想定)
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
