class CreateBacktestingTrades < ActiveRecord::Migration[8.1]
  def change
    create_table :backtesting_trades do |t|
      t.references :backtesting_run, null: false, foreign_key: true
      t.string :side, limit: 8, null: false
      t.datetime :entry_at, null: false
      t.datetime :exit_at, null: false
      t.decimal :entry_price, precision: 24, scale: 8, null: false
      t.decimal :exit_price, precision: 24, scale: 8, null: false
      t.decimal :quantity, precision: 24, scale: 8, null: false
      t.decimal :pnl, precision: 24, scale: 8, null: false
      t.timestamps
    end
  end
end
