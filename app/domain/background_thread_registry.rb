module Domain
  # WS callback / WS reconnect / algo anomaly 検出時に DB アクセスを別 thread で実行する際の
  # Thread 管理を担う Domain サービス.
  #
  # Phase 3.4a Step 0b-2 で Worker 責務縮小のため抽出した.
  # 元: LiveTradingWorker @background_threads / @background_threads_mutex /
  #     @last_background_thread_sweep_at + run_in_db_thread / sweep_background_threads /
  #     sweep_background_threads_if_due / join_background_threads + BACKGROUND_THREAD_* 定数.
  #
  # 責務:
  #   - 起動した Thread を thread-safe に保持(Mutex 保護)
  #   - spawn 時に AR connection_pool.with_connection で connection 確保 + 例外 logger.error 落とし
  #   - sweep_if_due で完了済 thread を周期的に除去(24h 稼働でのメモリリーク対策 / R-7 #C 反映)
  #   - join_all で finalize 時に timeout 付き join + kill(thread leak / AR pool 枯渇防止)
  #
  # 設計理由:
  #   - 元 Worker 内 run_in_db_thread の fire-and-forget による thread leak を回避するため,
  #     起動 Thread を保持して finalize で確実に解放する(multiple-agent review R-3 #7 反映).
  #   - sweep / join とも Mutex 内で `select!` / `dup` を使い non-atomic 操作を回避.
  class BackgroundThreadRegistry
    DEFAULT_SWEEP_INTERVAL_SECONDS = 60
    DEFAULT_JOIN_TIMEOUT_SECONDS = 10.0

    # @param monotonic_clock [#call] sweep 周期判定用 monotonic clock(壁時計逆行耐性 / R-2 #5 反映)
    # @param logger [Logger] background task 失敗時の error / join timeout 時の warn 出力先
    # @param sweep_interval_seconds [Numeric] 周期 sweep の最小間隔(秒)
    # @param join_timeout_seconds [Numeric] finalize 時 join の timeout(秒)
    def initialize(monotonic_clock:, logger: Rails.logger,
                   sweep_interval_seconds: DEFAULT_SWEEP_INTERVAL_SECONDS,
                   join_timeout_seconds: DEFAULT_JOIN_TIMEOUT_SECONDS)
      @monotonic_clock = monotonic_clock
      @logger = logger
      @sweep_interval_seconds = sweep_interval_seconds
      @join_timeout_seconds = join_timeout_seconds
      @threads = []
      @mutex = Mutex.new
      @last_sweep_at = nil
    end

    # 新規 Thread を起動して block を実行する.
    # AR connection_pool.with_connection で connection 確保 + StandardError rescue + logger.error 落とし.
    # 起動 Thread は内部配列に保持され,sweep_if_due / join_all で管理される.
    #
    # @param label [String] エラーログでの識別子
    # @return [Thread] 起動した Thread
    def spawn(label, &block)
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection(&block)
      rescue StandardError => e
        logger.error(
          "[BackgroundThreadRegistry] background task '#{label}' failed: " \
          "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
        )
      end

      @mutex.synchronize { @threads << thread }
      thread
    end

    # main loop iteration 内で sweep_interval_seconds 周期で完了済 thread を除去.
    # 周期未到達時は no-op.
    # `@last_sweep_at` の read-modify-write も Mutex 内で行い JIT / 将来の複数 caller への耐性を確保.
    #
    # @return [void]
    def sweep_if_due
      @mutex.synchronize do
        now = @monotonic_clock.call
        return if @last_sweep_at && (now - @last_sweep_at) < @sweep_interval_seconds

        @threads.select!(&:alive?)
        @last_sweep_at = now
      end
      nil
    end

    # finalize 時の thread 解放: 残存 thread を timeout 付きで join + 超過時は kill.
    # 終了後は内部配列から「dup 取得分のみ」を削除する(join 中に spawn された新規 thread は保持).
    #
    # @return [void]
    def join_all
      threads = @mutex.synchronize { @threads.dup }
      return if threads.empty?

      threads.each do |thread|
        thread.join(@join_timeout_seconds)
        next unless thread.alive?

        logger.warn(
          "[BackgroundThreadRegistry] background thread did not finish within " \
          "#{@join_timeout_seconds}s; killing"
        )
        thread.kill
      end

      target_set = threads.to_set
      @mutex.synchronize { @threads.delete_if { |t| target_set.include?(t) } }
      nil
    end

    # 保持 thread 数(spec / 観察用 helper).
    #
    # @return [Integer]
    def size
      @mutex.synchronize { @threads.size }
    end

    private

    attr_reader :logger
  end
end
