module Infrastructure
  # WS reconnect 連続失敗を window 内でカウントし,閾値超過時に logger.error で
  # アラート出力する(設計書 02_§4.2.8 / Phase 1.3 引き継ぎ #8)
  #
  # MVP では logger 出力のみ。将来的にメトリクス送信先(StatsD / Datadog 等)を
  # 拡張する場合は本クラスをインターフェースとして拡張する。
  class BitgetWsMetricsRecorder
    DEFAULT_THRESHOLD_COUNT = 5
    DEFAULT_WINDOW_SECONDS = 300

    # @param clock [#call] 現在時刻取得 Proc
    # @param logger [Logger]
    # @param threshold_count [Integer] window 内 N 回の失敗で警告
    # @param window_seconds [Integer] window の秒数
    def initialize(
      clock: Time.method(:current),
      logger: Rails.logger,
      threshold_count: DEFAULT_THRESHOLD_COUNT,
      window_seconds: DEFAULT_WINDOW_SECONDS
    )
      @clock = clock
      @logger = logger
      @threshold_count = threshold_count
      @window_seconds = window_seconds
      @failure_timestamps = []
    end

    # WS 失敗を記録 + window 内件数が threshold に達したらアラート
    def record_failure
      now = clock.call
      @failure_timestamps << now
      prune_old(now)
      return unless failure_count_in_window >= threshold_count

      logger.error(
        "[BitgetWsMetricsRecorder] repeated reconnect failures: " \
        "#{failure_count_in_window} times in #{window_seconds}s window"
      )
    end

    # WS 成功を記録 → 失敗カウントをリセット(連続失敗判定の打ち切り)
    def record_success
      @failure_timestamps = []
    end

    # window 内の失敗件数を返す
    #
    # @return [Integer]
    def failure_count_in_window
      now = clock.call
      prune_old(now)
      failure_timestamps.size
    end

    private

    attr_reader :clock, :logger, :threshold_count, :window_seconds, :failure_timestamps

    # window 外の古い timestamp を破棄
    def prune_old(now)
      cutoff = now - window_seconds
      @failure_timestamps = failure_timestamps.reject { |t| t < cutoff }
    end
  end
end
