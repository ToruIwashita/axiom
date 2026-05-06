class CreateExchangeOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :exchange_orders do |t|
      t.references :live_trading_trade, null: false, foreign_key: true
      t.references :strategy_revision, null: false, foreign_key: true
      t.string :bitget_order_id, limit: 64
      t.string :client_oid, limit: 64, null: false
      t.string :symbol, limit: 32, null: false
      t.string :side, limit: 8, null: false
      t.string :trade_side, limit: 8, null: false
      t.string :order_type, limit: 8, null: false
      t.decimal :price, precision: 30, scale: 12
      t.decimal :size, precision: 30, scale: 12, null: false
      t.string :status, limit: 32, null: false
      t.boolean :reduce_only, null: false, default: false
      t.string :force, limit: 16, null: false
      t.datetime :placed_at
      t.datetime :finished_at
      t.timestamps

      t.index :bitget_order_id, unique: true
      t.index :client_oid, unique: true
      t.index :status
    end
  end
end
