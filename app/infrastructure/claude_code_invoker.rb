require "open3"
require "timeout"

module Infrastructure
  # Claude Code CLI(`claude -p`)を Open3 で起動し,stdin → prompt 流入 → stdout 受信を行う
  # (設計書 04_§修正2 + 02_§5.2.3)
  #
  # ## フェイルセーフ階層(設計書 04_§9 / 「迷ったら動かない」原則)
  # - Timeout 発生 → nil 返却 + logger.warn
  # - CLI 異常終了(非 0 exit code)→ nil 返却 + logger.warn
  # - CLI 不在(Errno::ENOENT 等)→ nil 返却 + logger.warn
  # - その他 StandardError → nil 返却 + logger.warn
  #
  # ## 起動時チェック
  # cli_available? で `claude --version` を実行し,失敗時は LiveTradingWorker bootstrap で
  # セッション起動不可と判定する想定(Phase 3.3 後続 Step で連携)
  #
  # ## DI
  # - executor: Open3.method(:popen3)(default)/ spec で instance_double
  # - logger: Rails.logger
  class ClaudeCodeInvoker
    DEFAULT_INVOKE_COMMAND = [ "claude", "-p" ].freeze
    VERSION_CHECK_COMMAND = [ "claude", "--version" ].freeze

    private_constant :DEFAULT_INVOKE_COMMAND, :VERSION_CHECK_COMMAND

    # @param executor [#call] Open3.method(:popen3) 相当の DI 用
    # @param logger [Logger]
    def initialize(executor: Open3.method(:popen3), logger: Rails.logger)
      @executor = executor
      @logger = logger
    end

    # Claude Code CLI を呼び出して stdout を取得する
    #
    # @param prompt [String] CLI に渡す prompt
    # @param timeout_sec [Float] タイムアウト秒数
    # @return [String, nil] stdout 文字列(成功)/ nil(失敗・タイムアウト・CLI 不在)
    def invoke(prompt:, timeout_sec:)
      Timeout.timeout(timeout_sec) do
        stdin, stdout, stderr, wait_thread = executor.call(*DEFAULT_INVOKE_COMMAND)
        stdin.write(prompt)
        stdin.close
        result = stdout.read
        status = wait_thread.value
        return result if status.success?

        logger.warn("[ClaudeCodeInvoker] non-zero exit: #{stderr.read}")
        nil
      end
    rescue Timeout::Error
      logger.warn("[ClaudeCodeInvoker] timeout (timeout_sec=#{timeout_sec})")
      nil
    rescue StandardError => e
      logger.warn("[ClaudeCodeInvoker] error: #{e.class}: #{e.message}")
      nil
    end

    # Claude Code CLI が利用可能か確認する(LiveTradingWorker 起動時チェック用)
    #
    # @return [Boolean] `claude --version` が成功すれば true
    def cli_available?
      _stdin, _stdout, _stderr, wait_thread = executor.call(*VERSION_CHECK_COMMAND)
      wait_thread.value.success?
    rescue StandardError
      false
    end

    private

    attr_reader :executor, :logger
  end
end
