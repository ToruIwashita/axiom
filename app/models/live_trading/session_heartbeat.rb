module LiveTrading
  class SessionHeartbeat < ApplicationRecord
    self.table_name = "live_trading_session_heartbeats"

    belongs_to :live_trading_session, class_name: "LiveTrading::Session"

    validates :worker_instance_id, presence: true, length: { maximum: 64 }
    validates :pulsed_at, presence: true

    # Heartbeat を打鍵する(設計書 05_§7.2: heartbeat 周期 60 秒推奨)
    #
    # @param session_id [Integer] LiveTrading::Session の ID
    # @param worker_instance_id [String] Worker プロセス識別子
    # @param pulsed_at [Time] 打鍵時刻
    # @return [LiveTrading::SessionHeartbeat] 作成された Heartbeat レコード
    def self.pulse!(session_id:, worker_instance_id:, pulsed_at: Time.current)
      create!(
        live_trading_session_id: session_id,
        worker_instance_id: worker_instance_id,
        pulsed_at: pulsed_at
      )
    end

    # 最新 N 件の Heartbeat を pulsed_at 降順で返す
    #
    # @param limit [Integer] 取得件数上限
    # @return [ActiveRecord::Relation<LiveTrading::SessionHeartbeat>]
    def self.recent(limit)
      order(pulsed_at: :desc).limit(limit)
    end
  end
end
