module MarketData
  class IndexCandle < ApplicationRecord
    self.table_name = "market_data_index_candles"

    validates :symbol, presence: true
    validates :granularity, presence: true
    validates :ts, presence: true
    validates :open, :high, :low, :close, presence: true
  end
end
