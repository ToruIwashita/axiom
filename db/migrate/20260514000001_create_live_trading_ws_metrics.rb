class CreateLiveTradingWsMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :live_trading_ws_metrics do |t|
      t.references :live_trading_session, null: false, foreign_key: true, index: true
      t.datetime :detected_at, null: false
      # Phase 4.2 + 高-2 反映: Worker perform 開始を起点とする累積カウント.
      # Worker 再起動(Sidekiq retry / 別ノード移譲)で WS Client 再生成 → @reconnect_count 0 リセットされるため,
      # 新 Worker の perform 内で 0 から再開する仕様(過去累積を引き継がない / Worker 寿命内累積).
      t.integer :public_count_since_start, null: false, default: 0
      t.integer :private_count_since_start, null: false, default: 0
      # Worker ローカル変数 `last_recorded_*` を起点とする差分(高-2 反映 / `>= 0` 制約は Model validation 側でも緩和)
      t.integer :delta_public, null: false, default: 0
      t.integer :delta_private, null: false, default: 0
      # 低-7 反映: reason を構造化(WS Client の `@last_disconnect_reason` 経由で WsReconnectDetector が同梱)
      t.string :source_event, limit: 32   # close / error / heartbeat_timeout
      t.string :target_ws, limit: 16      # public / private / both
      # 新-中-4 反映: Worker 境界識別子(SessionHeartbeat と同流儀).
      # UI で Worker 別グループ化表示し,Worker 跨ぎの「単調減少」時系列混乱を回避.
      t.string :worker_instance_id, limit: 64, null: false
      t.timestamps
    end

    add_index :live_trading_ws_metrics,
              [ :live_trading_session_id, :detected_at ],
              name: "idx_lt_ws_metrics_session_detected_at"
    add_index :live_trading_ws_metrics,
              [ :live_trading_session_id, :worker_instance_id, :detected_at ],
              name: "idx_lt_ws_metrics_session_worker_detected_at"
  end
end
