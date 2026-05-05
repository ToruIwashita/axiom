class CreateLiveTradingSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :live_trading_sessions do |t|
      t.references :strategy_definition, null: false, foreign_key: true
      t.references :strategy_revision, null: false, foreign_key: true
      t.references :risk_policy, null: false, foreign_key: true
      t.string :symbol, limit: 32, null: false
      t.integer :leverage, null: false
      t.string :margin_mode, limit: 16, null: false
      t.string :position_mode, limit: 16, null: false
      t.string :asset_mode, limit: 16, null: false
      t.string :margin_coin, limit: 16, null: false
      t.string :emergency_stop_mode, limit: 32, null: false
      t.string :status, limit: 32, null: false
      t.string :worker_instance_id, limit: 64
      t.text :failure_reason
      t.datetime :started_at
      t.datetime :stopped_at
      t.timestamps

      t.index :status
      t.index :symbol
    end
  end
end
