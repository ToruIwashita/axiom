class CreateBacktestingMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :backtesting_metrics do |t|
      t.references :backtesting_run, null: false, foreign_key: true, index: { unique: true }
      t.decimal :win_rate, precision: 6, scale: 4, null: false
      t.decimal :total_pnl, precision: 24, scale: 8, null: false
      t.decimal :max_drawdown, precision: 24, scale: 8, null: false
      t.decimal :sharpe_ratio, precision: 12, scale: 6, null: false
      t.decimal :sortino_ratio, precision: 12, scale: 6, null: false
      t.decimal :volatility, precision: 12, scale: 6, null: false
      t.decimal :profit_factor, precision: 12, scale: 6, null: false
      t.integer :total_trades, null: false
      t.integer :avg_holding_seconds, null: false
      t.timestamps
    end
  end
end
