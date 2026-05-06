class CreateLiveTradingSessionLeases < ActiveRecord::Migration[8.1]
  def change
    create_table :live_trading_session_leases do |t|
      t.references :live_trading_session, null: false, foreign_key: true, index: { unique: true }
      t.string :lease_token, limit: 64, null: false
      t.string :worker_instance_id, limit: 64, null: false
      t.datetime :acquired_at, null: false
      t.datetime :renewed_at
      t.datetime :expires_at, null: false
      t.string :status, limit: 16, null: false
      t.timestamps

      t.index :lease_token, unique: true
      t.index :status
    end
  end
end
