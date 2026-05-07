#!/usr/bin/env ruby
# frozen_string_literal: true

# 戦略実行子プロセス共通基盤(Phase 2 引き継ぎ #15 / Step 3.3-6).
#
# `lib/strategy_runner_child.rb`(Phase 1.2)/ `lib/backtest_runner_child.rb`(Phase 2.1)/
# `lib/live_runner_child.rb`(Phase 3.3b)の 3 ファイルで重複していた以下を共通化する:
#
# - SCHEMA_VERSION / setrlimit 定数
# - setrlimit インライン適用(macOS Darwin 環境向け Errno::EINVAL rescue 込み)
# - emit_error_response(error JSON 整形)
# - load_and_verify_input!(stdin 読み込み + JSON parse + script_checksum 照合)
#
# B 案 / 完全不変保護方針(02_§0.4): Infrastructure::* 名前空間は参照せず,
# Ruby 標準ライブラリ(JSON / Digest)のみ require する.

require "json"
require "digest"

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

# stdin から JSON 入力を読み込み, script_checksum 照合まで行う.
# 失敗時は emit_error_response + exit 0 で子プロセスを終了する.
# 成功時は parse 済みの input(Hash)を返す.
def load_and_verify_input!
  raw_input = $stdin.read
  begin
    input = JSON.parse(raw_input)
  rescue JSON::ParserError => e
    emit_error_response(nil, error_class: "JsonParseError", message: e.message)
    exit 0
  end

  callback_name = input["callback"]
  computed_checksum = Digest::SHA256.hexdigest(input["script_content"])
  unless computed_checksum == input["script_checksum"]
    emit_error_response(callback_name, error_class: "ScriptIntegrityError", message: "checksum mismatch")
    exit 0
  end

  input
end
