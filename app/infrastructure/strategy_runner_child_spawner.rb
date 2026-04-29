require "open3"

module Infrastructure
  # callback単位で戦略実行用の子プロセス(別Rubyインタプリタ)を起動し,
  # IPC(JSON over stdin/stdout)で入出力を交換する Spawner.
  #
  # 子プロセスは `lib/strategy_runner_child.rb` を `Open3.popen3` で別 Ruby インタプリタ
  # として起動し,Rails 環境を継承しない(05_§1.7.1 / 02_§2.3 (B)案).
  #
  # 親プロセスは `IO.select` で wall clock timeout を監視し,timeout 時には
  # `Process.kill("KILL", child_pid)` で子プロセスを停止する(05_§1.7.2).
  # 正常終了 / timeout / 異常 の全パスで `ensure` ブロック内 `wait_thread.value` を呼び
  # zombie を reap する(レビュー指摘 重要3).
  #
  # `JSON.parse` 失敗時には `{ status: "error", errors: [{ class: "JsonParseError", ... }] }` を
  # 返すフォールバックを実装する(レビュー指摘 重要4).
  class StrategyRunnerChildSpawner
    DEFAULT_TIMEOUTS = {
      "on_start" => 5.0,
      "on_tick" => 0.5,
      "on_order_event" => 1.0,
      "on_stop" => 5.0
    }.freeze
    DEFAULT_RUNNER_SCRIPT = Rails.root.join("lib/strategy_runner_child.rb").to_s
    SCHEMA_VERSION = "1.0".freeze

    # @param ipc_protocol [Infrastructure::StrategyRunnerIpcProtocol, nil] DI(nil なら新規生成)
    # @param resource_limiter [Infrastructure::StrategyRunnerResourceLimiter, nil] DI(nil なら新規生成)
    # @param runner_script_path [String] 子プロセス起動用 Ruby script のパス
    # @param timeouts [Hash{String => Float}] callback種別ごとの wall clock timeout(秒)
    def initialize(
      ipc_protocol: nil,
      resource_limiter: nil,
      runner_script_path: DEFAULT_RUNNER_SCRIPT,
      timeouts: DEFAULT_TIMEOUTS
    )
      @ipc_protocol = ipc_protocol || Infrastructure::StrategyRunnerIpcProtocol.new
      @resource_limiter = resource_limiter || Infrastructure::StrategyRunnerResourceLimiter.new
      @runner_script_path = runner_script_path
      @timeouts = timeouts
    end

    # callback単位で子プロセスを起動し戦略を実行する
    #
    # @param callback [Symbol, String] :on_start / :on_tick / :on_order_event / :on_stop
    # @param revision [Strategy::Revision] 対象Revision
    # @param ctx_input [Hash] 親→子 IPC ctx_input(candle, event, state, balance 等)
    # @return [Hash] 子プロセスからの IPC 返却 Hash(schema_version, callback, status,
    #   order_intents, logs, errors, strategy_state_diff)
    # @raise [ArgumentError] callback / Revision の整合性エラー(IPC schema validation 失敗)
    def run(callback:, revision:, ctx_input:)
      callback_name = callback.to_s
      timeout_sec = timeouts.fetch(callback_name)
      request = build_request(callback: callback_name, revision: revision, ctx_input: ctx_input)
      ipc_protocol.validate_request(request)

      stdin = stdout = stderr = wait_thread = nil

      begin
        stdin, stdout, stderr, wait_thread = Open3.popen3(
          resource_limiter.minimal_env,
          "ruby", runner_script_path,
          unsetenv_others: true
        )
        stdin.write(request.to_json)
        stdin.close

        ready, = IO.select([ stdout ], nil, nil, timeout_sec)
        return handle_timeout(callback_name, wait_thread.pid, timeout_sec) if ready.nil?

        raw_output = stdout.read

        response =
          begin
            JSON.parse(raw_output)
          rescue JSON::ParserError => e
            return error_result(callback_name, status: "error",
                                error_class: "JsonParseError",
                                message: e.message,
                                raw_output: raw_output)
          end

        ipc_protocol.validate_response(response)
        response
      ensure
        close_stream(stdin)
        close_stream(stdout)
        close_stream(stderr)
        wait_thread&.value
      end
    end

    private

    attr_reader :ipc_protocol, :resource_limiter, :runner_script_path, :timeouts

    def build_request(callback:, revision:, ctx_input:)
      {
        "schema_version" => SCHEMA_VERSION,
        "callback" => callback,
        "script_content" => revision.script_content,
        "script_checksum" => revision.script_checksum,
        "script_entrypoint" => revision.script_entrypoint,
        "ctx_input" => ctx_input
      }
    end

    def handle_timeout(callback_name, child_pid, timeout_sec)
      Process.kill("KILL", child_pid)
      error_result(callback_name, status: "timeout",
                   error_class: "TimeoutError",
                   message: "Wall clock timeout after #{timeout_sec}s")
    end

    def error_result(callback_name, status:, error_class:, message:, raw_output: nil)
      error_entry = { "class" => error_class, "message" => message }
      error_entry["raw_output"] = raw_output if raw_output
      {
        "schema_version" => SCHEMA_VERSION,
        "callback" => callback_name,
        "status" => status,
        "order_intents" => [],
        "logs" => [],
        "errors" => [ error_entry ],
        "strategy_state_diff" => { "ops" => [] }
      }
    end

    def close_stream(stream)
      return if stream.nil?
      return if stream.respond_to?(:closed?) && stream.closed?

      stream.close
    end
  end
end
