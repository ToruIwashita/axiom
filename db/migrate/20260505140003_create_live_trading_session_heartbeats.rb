class CreateLiveTradingSessionHeartbeats < ActiveRecord::Migration[8.1]
  def change
    create_table :live_trading_session_heartbeats do |t|
      t.references :live_trading_session, null: false, foreign_key: true
      t.string :worker_instance_id, limit: 64, null: false
      t.datetime :pulsed_at, null: false
      t.timestamps

      t.index [ :live_trading_session_id, :pulsed_at ],
              name: "idx_lt_heartbeats_session_pulsed_at"
    end
  end
end
