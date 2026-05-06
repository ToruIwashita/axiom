module LiveTrading
  class SessionLease < ApplicationRecord
    self.table_name = "live_trading_session_leases"

    class ActiveLeaseError < StandardError; end

    STATUSES = %w[active released expired].freeze
    DEFAULT_TTL_SECONDS = 300

    enum :status, STATUSES.index_with(&:itself), prefix: :state

    belongs_to :live_trading_session, class_name: "LiveTrading::Session"

    validates :lease_token, presence: true, uniqueness: true, length: { maximum: 64 }
    validates :worker_instance_id, presence: true, length: { maximum: 64 }
    validates :acquired_at, presence: true
    validates :expires_at, presence: true
    validates :status, presence: true
    validates :live_trading_session_id, uniqueness: true

    # Lease を取得する(設計書 05_§7.2: lease TTL 5 分推奨)
    # Phase 3.1 レビュー R-4 反映: idempotent 化
    # - 既存 released / expired レコード,または期限切れ active があれば update! で再利用
    # - 既存 active かつ期限内なら ActiveLeaseError raise(二重起動防止)
    # - 既存レコードがなければ新規 create!
    #
    # @param session_id [Integer] LiveTrading::Session の ID
    # @param worker_instance_id [String] Worker プロセス識別子
    # @param ttl_seconds [Integer] TTL 秒数(デフォルト 300 秒)
    # @param acquired_at [Time] 取得時刻
    # @return [LiveTrading::SessionLease] 取得済の Lease
    # @raise [ActiveLeaseError] 既存の active かつ期限内 lease が存在する場合
    def self.acquire!(session_id:, worker_instance_id:, ttl_seconds: DEFAULT_TTL_SECONDS, acquired_at: Time.current)
      attrs = {
        lease_token: SecureRandom.uuid,
        worker_instance_id: worker_instance_id,
        acquired_at: acquired_at,
        renewed_at: nil,
        expires_at: acquired_at + ttl_seconds,
        status: "active"
      }

      existing = find_by(live_trading_session_id: session_id)
      if existing
        if existing.state_active? && !existing.expired?(now: acquired_at)
          raise ActiveLeaseError,
                "session #{session_id} already has active lease (worker=#{existing.worker_instance_id})"
        end

        existing.update!(attrs)
        return existing
      end

      create!(attrs.merge(live_trading_session_id: session_id))
    end

    # active かつ有効期限内の Lease を返すスコープ
    #
    # @param now [Time] 現在時刻判定基準
    # @return [ActiveRecord::Relation<LiveTrading::SessionLease>]
    def self.active(now: Time.current)
      where(status: "active").where("expires_at > ?", now)
    end

    # Lease の有効期限を更新する(Worker による定期 renew)
    #
    # @param new_expires_at [Time] 新しい expires_at
    # @param renewed_at [Time] renew 実行時刻
    # @return [Boolean] update! の結果
    def renew!(new_expires_at:, renewed_at: Time.current)
      update!(expires_at: new_expires_at, renewed_at: renewed_at)
    end

    # Lease を解放する(disconnect / 正常停止時)
    #
    # @return [Boolean] update! の結果
    def release!
      update!(status: "released")
    end

    # Lease の有効期限切れ判定
    #
    # @param now [Time] 判定基準時刻
    # @return [Boolean] expires_at を超えていれば true
    def expired?(now: Time.current)
      now > expires_at
    end
  end
end
