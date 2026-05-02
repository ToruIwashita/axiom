module Backtesting
  class EquityCurvePoint < ApplicationRecord
    self.table_name = "backtesting_equity_curve_points"

    belongs_to :run,
               class_name: "Backtesting::Run",
               foreign_key: :backtesting_run_id

    validates :ts, presence: true
    validates :equity, presence: true
    validates :position_size, presence: true
  end
end
