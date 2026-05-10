module Domain
  # main loop iteration ごとに heartbeat / lease renew の周期判定 + 起動を担う Domain サービス.
  #
  # Phase 3.4a Step 0b-4 で Worker 責務縮小のため抽出した.
  # 元: LiveTradingWorker @last_heartbeat_at / @last_lease_renew_at +
  #     pulse_heartbeat_if_due / renew_lease_if_due + HEARTBEAT_INTERVAL_SECONDS /
  #     LEASE_RENEW_INTERVAL_SECONDS.
  #
  # 責務:
  #   - heartbeat / lease renew の最終実行時刻を保持
  #   - 周期判定(monotonic_clock 経由 / 壁時計逆行耐性 / R-2 #5 反映)
  #   - 周期到達時に process_manager.pulse_heartbeat! / renew_lease! を呼出
  #   - 失敗時 logger.warn 落とし(main loop を止めない)+ sanitize 適用
  #
  # main loop は単一 thread で sequential に呼ぶため Mutex は不要.
  # heartbeat 60s / lease renew 120s は MVP デフォルト(設計書 05_§7.2 整合).
  class HeartbeatScheduler
    DEFAULT_HEARTBEAT_INTERVAL_SECONDS = 60
    DEFAULT_LEASE_RENEW_INTERVAL_SECONDS = 120

    # @param process_manager [Domain::LiveTradingProcessManager] pulse_heartbeat! / renew_lease! 呼出先
    # @param monotonic_clock [#call] 周期判定用 monotonic clock(壁時計逆行耐性)
    # @param logger [Logger] 失敗時の warn 出力先
    # @param heartbeat_interval_seconds [Numeric] heartbeat 周期(秒)
    # @param lease_renew_interval_seconds [Numeric] lease renew 周期(秒)
    def initialize(process_manager:, monotonic_clock:, logger: Rails.logger,
                   heartbeat_interval_seconds: DEFAULT_HEARTBEAT_INTERVAL_SECONDS,
                   lease_renew_interval_seconds: DEFAULT_LEASE_RENEW_INTERVAL_SECONDS)
      @process_manager = process_manager
      @monotonic_clock = monotonic_clock
      @logger = logger
      @heartbeat_interval_seconds = heartbeat_interval_seconds
      @lease_renew_interval_seconds = lease_renew_interval_seconds
      @last_heartbeat_at = nil
      @last_lease_renew_at = nil
    end

    # 周期到達時に process_manager.pulse_heartbeat! を呼ぶ.
    # 初回(@last_heartbeat_at が nil)は即時実行.
    # 失敗時は logger.warn 落とし(main loop を止めない).
    #
    # @param session [LiveTrading::Session]
    # @param worker_instance_id [String]
    # @return [void]
    def pulse_heartbeat_if_due(session:, worker_instance_id:)
      now = @monotonic_clock.call
      return if @last_heartbeat_at && (now - @last_heartbeat_at) < @heartbeat_interval_seconds

      @process_manager.pulse_heartbeat!(session: session, worker_instance_id: worker_instance_id)
      @last_heartbeat_at = now
      nil
    rescue StandardError => e
      logger.warn(
        "[HeartbeatScheduler] pulse_heartbeat! failed: " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
      nil
    end

    # 周期到達時に process_manager.renew_lease! を呼ぶ.
    # 初回(@last_lease_renew_at が nil)は即時実行 / lease が nil なら no-op.
    #
    # @param lease [LiveTrading::SessionLease, nil]
    # @return [void]
    def renew_lease_if_due(lease:)
      now = @monotonic_clock.call
      return if @last_lease_renew_at && (now - @last_lease_renew_at) < @lease_renew_interval_seconds
      return unless lease

      @process_manager.renew_lease!(lease: lease)
      @last_lease_renew_at = now
      nil
    rescue StandardError => e
      logger.warn(
        "[HeartbeatScheduler] renew_lease! failed: " \
        "#{e.class.name}: #{Domain::FailureReasonSanitizer.sanitize(e.message)}"
      )
      nil
    end

    # 最終実行時刻をクリアする(main loop 開始時に呼ぶ / 次回呼出が即実行される).
    #
    # @return [void]
    def reset
      @last_heartbeat_at = nil
      @last_lease_renew_at = nil
      nil
    end

    private

    attr_reader :logger
  end
end
