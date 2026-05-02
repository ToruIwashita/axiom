module Backtesting
  class Metrics < ApplicationRecord
    self.table_name = "backtesting_metrics"

    belongs_to :run,
               class_name: "Backtesting::Run",
               foreign_key: :backtesting_run_id,
               inverse_of: :metrics

    validates :win_rate,
              presence: true,
              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :total_pnl, presence: true
    validates :max_drawdown,
              presence: true,
              numericality: { greater_than_or_equal_to: 0 }
    validates :sharpe_ratio, presence: true
    validates :sortino_ratio, presence: true
    validates :volatility,
              presence: true,
              numericality: { greater_than_or_equal_to: 0 }
    validates :profit_factor,
              presence: true,
              numericality: { greater_than_or_equal_to: 0 }
    validates :total_trades,
              presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :avg_holding_seconds,
              presence: true,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :backtesting_run_id, uniqueness: true
  end
end
