class CreateLiveTradingTrades < ActiveRecord::Migration[8.1]
  def change
    create_table :live_trading_trades do |t|
      t.references :live_trading_session, null: false, foreign_key: true
      t.references :strategy_revision, null: false, foreign_key: true
      t.string :symbol, limit: 32, null: false
      t.string :side, limit: 8, null: false
      t.decimal :quantity, precision: 30, scale: 12, null: false
      t.decimal :entry_price, precision: 30, scale: 12
      t.datetime :entry_at
      t.decimal :exit_price, precision: 30, scale: 12
      t.datetime :exit_at
      t.decimal :realized_pnl, precision: 30, scale: 12
      t.string :status, limit: 16, null: false
      t.text :failure_reason
      t.timestamps

      t.index :status
    end
  end
end
