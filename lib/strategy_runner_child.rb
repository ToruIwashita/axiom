#!/usr/bin/env ruby
# frozen_string_literal: true

# 戦略実行子プロセスのエントリポイント.
#
# 親プロセス(`Infrastructure::StrategyRunnerChildSpawner`)から
# `Open3.popen3 ruby lib/strategy_runner_child.rb` で別 Ruby インタプリタとして起動される.
# Rails 環境を継承せず,JSON / Digest / Open3 の Ruby 標準ライブラリのみ require する.
#
# レビュー指摘 重要1 (B)案 に従い `Infrastructure::*` 名前空間は一切参照せず,
# setrlimit / checksum 検証 / エラー JSON 整形 を `lib/runner_child_common.rb` で共通化している
# (Phase 2 引き継ぎ #15 / Step 3.3-6).

require_relative "runner_child_common"
require "ostruct"

input = load_and_verify_input!
callback_name = input["callback"]

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
