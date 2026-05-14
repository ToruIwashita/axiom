module LiveTrading
  # WebSocket 再接続メトリクス(Phase 4.2).
  #
  # ## 仕様(設計書 02_§3.3-3.4 / 高-2 反映)
  # `public_count_since_start` / `private_count_since_start` は **Worker perform 開始時点を起点とする累積**.
  # Worker 再起動(Sidekiq retry / 別ノード移譲)で WS Client 再生成 → `@reconnect_count` 0 リセットされるため,
  # 新 Worker の perform 内で 0 から再開する.過去の累積を引き継がず,Worker 寿命内で意味を持つ累積値として扱う.
  #
  # `delta_public` / `delta_private` も Worker ローカル変数 `last_recorded_*_count`(初期値 0 / DB 参照しない)
  # を起点とする差分.
  #
  # validation は `numericality: { only_integer: true }` のみ(`>= 0` 制約は外す / Worker 跨ぎ補正前提で許容).
  #
  # `worker_instance_id`(新-中-4 反映)で Worker 境界を識別し,UI で Worker 別グループ化表示することで
  # 「単調減少」時系列混乱を回避する.
  #
  # `source_event` / `target_ws`(低-7 反映)は WsReconnectDetector が WS Client の `last_disconnect_reason` を
  # 取り込んで同梱する Symbol を String 化した値が記録される.
  class WsMetric < ApplicationRecord
    self.table_name = "live_trading_ws_metrics"

    SOURCE_EVENTS = %w[close error heartbeat_timeout].freeze
    TARGET_WS = %w[public private both].freeze

    belongs_to :session, class_name: "LiveTrading::Session", foreign_key: :live_trading_session_id

    validates :detected_at, presence: true
    validates :public_count_since_start, presence: true, numericality: { only_integer: true }
    validates :private_count_since_start, presence: true, numericality: { only_integer: true }
    validates :delta_public, presence: true, numericality: { only_integer: true }
    validates :delta_private, presence: true, numericality: { only_integer: true }
    validates :source_event, inclusion: { in: SOURCE_EVENTS }, allow_nil: true
    validates :target_ws, inclusion: { in: TARGET_WS }, allow_nil: true
    validates :worker_instance_id, presence: true, length: { maximum: 64 }

    scope :recent, ->(limit) { order(detected_at: :desc).limit(limit) }
    scope :by_worker, ->(wid) { where(worker_instance_id: wid) }
  end
end
