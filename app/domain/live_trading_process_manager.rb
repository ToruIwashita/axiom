module Domain
  # ライブトレード Worker のプロセス起動 / lease 取得 / heartbeat 監視を一元化する
  # stateless な Domain サービス(設計書 03_§9.3 / 02_§5.2.5).
  #
  # `LiveTradingWorker` は Sidekiq の入口に徹し, lease / heartbeat / kill-switch 判定の
  # ロジックは本サービスへ委譲する. 各メソッドは session を引数で受け取り内部状態を持たない.
  #
  # TTL / 周期(設計書 05_§7.2):
  # - lease TTL 5 分(`LiveTrading::SessionLease::DEFAULT_TTL_SECONDS`)
  # - heartbeat 周期 60 秒
  # - lease renew 周期 2 分
  class LiveTradingProcessManager
    # @param clock [#call] 時刻取得関数(テスト時に固定時刻を注入するため DI)
    def initialize(clock: -> { Time.current })
      @clock = clock
    end

    # Lease を取得する(LiveTrading::SessionLease.acquire! へ delegate).
    #
    # @param session [LiveTrading::Session] 対象セッション
    # @param worker_instance_id [String] Worker プロセス識別子
    # @return [LiveTrading::SessionLease] 取得済の Lease
    # @raise [LiveTrading::SessionLease::ActiveLeaseError] 既に active な lease が存在する場合
    def acquire_lease!(session:, worker_instance_id:)
      LiveTrading::SessionLease.acquire!(
        session_id: session.id,
        worker_instance_id: worker_instance_id,
        acquired_at: @clock.call
      )
    end

    # Heartbeat を打鍵する(LiveTrading::SessionHeartbeat.pulse! へ delegate).
    #
    # @param session [LiveTrading::Session] 対象セッション
    # @param worker_instance_id [String] Worker プロセス識別子
    # @return [LiveTrading::SessionHeartbeat] 作成された Heartbeat
    def pulse_heartbeat!(session:, worker_instance_id:)
      LiveTrading::SessionHeartbeat.pulse!(
        session_id: session.id,
        worker_instance_id: worker_instance_id,
        pulsed_at: @clock.call
      )
    end

    # Lease の有効期限を延長する.
    # 新 expires_at = clock.now + DEFAULT_TTL_SECONDS.
    #
    # @param lease [LiveTrading::SessionLease] 対象 lease
    # @return [LiveTrading::SessionLease] 更新済の lease
    def renew_lease!(lease:)
      now = @clock.call
      lease.renew!(
        new_expires_at: now + LiveTrading::SessionLease::DEFAULT_TTL_SECONDS,
        renewed_at: now
      )
      lease
    end

    # Lease を解放する(disconnect / 正常停止時).
    #
    # @param lease [LiveTrading::SessionLease] 対象 lease
    # @return [LiveTrading::SessionLease] 解放済の lease
    def release_lease!(lease:)
      lease.release!
      lease
    end

    # kill-switch シグナル(session.status == :stopping)が立っているか判定する.
    #
    # @param session [LiveTrading::Session] 対象セッション
    # @return [Boolean] stopping 状態であれば true
    def signal_kill_switch?(session:)
      session.reload.state_stopping?
    end
  end
end
