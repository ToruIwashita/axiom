module MarketData
  class FuturesCandle < ApplicationRecord
    self.table_name = "market_data_futures_candles"

    validates :symbol, presence: true
    validates :granularity, presence: true
    validates :ts, presence: true
    validates :open, :high, :low, :close, presence: true
  end
end
