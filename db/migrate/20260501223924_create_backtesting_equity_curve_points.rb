class CreateBacktestingEquityCurvePoints < ActiveRecord::Migration[8.1]
  def change
    create_table :backtesting_equity_curve_points do |t|
      t.references :backtesting_run, null: false, foreign_key: true
      t.datetime :ts, null: false
      t.decimal :equity, precision: 24, scale: 8, null: false
      t.decimal :drawdown, precision: 24, scale: 8
      t.decimal :position_size, precision: 24, scale: 8, null: false
      t.timestamps

      t.index [:backtesting_run_id, :ts], name: "idx_equity_curve_run_ts"
    end
  end
end
