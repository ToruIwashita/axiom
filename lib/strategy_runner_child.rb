#!/usr/bin/env ruby
# frozen_string_literal: true

# 戦略実行子プロセスのエントリポイント.
#
# 親プロセス(`Infrastructure::StrategyRunnerChildSpawner`)から
# `Open3.popen3 ruby lib/strategy_runner_child.rb` で別 Ruby インタプリタとして起動される.
# Rails 環境を継承せず,JSON / Digest / Open3 の Ruby 標準ライブラリのみ require する.
#
# レビュー指摘 重要1 (B)案 に従い `Infrastructure::*` 名前空間は一切参照せず,
# setrlimit / checksum 検証 / エラー JSON 整形 を全てインライン定義する.

require "json"
require "digest"
require "ostruct"

SCHEMA_VERSION = "1.0"
DEFAULT_CPU_SECONDS = 1
DEFAULT_MEMORY_BYTES = 256 * 1024 * 1024

# === setrlimit インライン適用(05_§1.7.2) ===
# macOS / Darwin では RLIMIT_AS が EINVAL で拒否されるため rescue で守る(02_§注意事項).
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

# === script_checksum 照合(05_§1.7.5) ===
computed_checksum = Digest::SHA256.hexdigest(input["script_content"])
unless computed_checksum == input["script_checksum"]
  emit_error_response(callback_name, error_class: "ScriptIntegrityError", message: "checksum mismatch")
  exit 0
end

# === Domain::TradingScriptBase 読み込み(zeitwerk なし環境) ===
trading_script_base_path = File.expand_path("../app/domain/trading_script_base", __dir__)
require trading_script_base_path

# === eval + callback 実行 ===
# TOPLEVEL_BINDING を明示することで戦略 class を Object 直下の定数として登録する
# (eval をトップレベルで呼んでも begin/rescue ブロック内のローカルスコープになるため).
begin
  TOPLEVEL_BINDING.eval(input["script_content"]) # rubocop:disable Security/Eval
  strategy_class = Object.const_get(input["script_entrypoint"])
  strategy = strategy_class.new

  ctx_input = input["ctx_input"] || {}
  ctx = OpenStruct.new(ctx_input)

  case callback_name
  when "on_start"
    strategy.on_start(ctx)
  when "on_tick"
    candle_data = ctx_input["candle"]
    candle = candle_data.is_a?(Hash) ? OpenStruct.new(candle_data) : candle_data
    strategy.on_tick(ctx, candle)
  when "on_order_event"
    event_data = ctx_input["event"]
    event = event_data.is_a?(Hash) ? OpenStruct.new(event_data) : event_data
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
    "order_intents" => [],
    "logs" => [],
    "errors" => [],
    "strategy_state_diff" => { "ops" => [] }
  }.to_json)
rescue => e # rubocop:disable Style/RescueStandardError
  emit_error_response(callback_name, error_class: e.class.name, message: e.message, backtrace: e.backtrace&.first(10))
  exit 0
end
