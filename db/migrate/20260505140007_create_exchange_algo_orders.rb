class CreateExchangeAlgoOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :exchange_algo_orders do |t|
      t.references :live_trading_trade, null: false, foreign_key: true
      t.references :strategy_revision, null: false, foreign_key: true
      t.string :algo_type, limit: 16, null: false
      t.string :bitget_algo_id, limit: 64, null: false
      t.decimal :trigger_price, precision: 30, scale: 12, null: false
      t.decimal :execute_price, precision: 30, scale: 12
      t.decimal :callback_ratio, precision: 8, scale: 6
      t.string :status, limit: 16, null: false
      t.timestamps

      t.index :bitget_algo_id, unique: true
      t.index :status
    end
  end
end
