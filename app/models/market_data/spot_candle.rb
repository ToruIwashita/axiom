module MarketData
  class SpotCandle < ApplicationRecord
    self.table_name = "market_data_spot_candles"

    validates :symbol, presence: true
    validates :granularity, presence: true
    validates :ts, presence: true
    validates :open, :high, :low, :close, presence: true
  end
end
