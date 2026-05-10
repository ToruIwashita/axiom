module Domain
  # WS push burst による reconciliation thread 爆発防止のための debounce + in-progress 制御.
  #
  # Phase 3.4a Step 0b-1 で Worker 責務縮小のため抽出した.
  # 元: LiveTradingWorker @anomaly_reconcile_in_progress / @anomaly_reconcile_mutex /
  #     @last_anomaly_reconcile_at + acquire_/release_anomaly_reconcile_slot.
  #
  # 責務:
  #   - in-progress フラグの thread-safe 管理(Mutex 保護)
  #   - 前回取得から DEBOUNCE_SECONDS 未満の再取得を抑止
  #   - try_acquire で取得可否を返却 / release で in-progress 解除
  #
  # 利用パターン(Worker 側):
  #   return unless debouncer.try_acquire
  #   run_in_db_thread("...") do
  #     begin
  #       # reconciliation 実行
  #     ensure
  #       debouncer.release
  #     end
  #   end
  #
  # 注意: release は spawn thread の完了時(ensure)に呼ぶ設計.
  # synchronous な with_slot ブロック helper は提供しない(release タイミングが
  # 「spawn thread 内」vs「synchronous block 終了時」で異なるため).
  class AnomalyReconcileDebouncer
    DEFAULT_DEBOUNCE_SECONDS = 30

    # @param monotonic_clock [#call] 経過時間判定に使う monotonic clock(壁時計逆行耐性 / R-2 #5 反映)
    # @param debounce_seconds [Numeric] 連続取得抑止の最小間隔(秒)
    def initialize(monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   debounce_seconds: DEFAULT_DEBOUNCE_SECONDS)
      @monotonic_clock = monotonic_clock
      @debounce_seconds = debounce_seconds
      @in_progress = false
      @last_acquired_at = nil
      @mutex = Mutex.new
    end

    # 取得可否を判定. 取得成功時に in-progress = true + last_acquired_at 更新.
    # in-progress 中, または前回取得から debounce_seconds 未満なら false 返却.
    #
    # @return [Boolean] 取得成功 true / 失敗 false
    def try_acquire
      @mutex.synchronize do
        return false if @in_progress

        now = @monotonic_clock.call
        return false if @last_acquired_at && (now - @last_acquired_at) < @debounce_seconds

        @in_progress = true
        @last_acquired_at = now
        true
      end
    end

    # in-progress フラグを解除する.
    # release のみでは debounce_seconds 内の再取得は許可されない(意図的 / burst 抑止).
    #
    # @return [void]
    def release
      @mutex.synchronize { @in_progress = false }
      nil
    end
  end
end
