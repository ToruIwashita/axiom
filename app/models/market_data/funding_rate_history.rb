module MarketData
  class FundingRateHistory < ApplicationRecord
    self.table_name = "market_data_funding_rate_histories"

    validates :symbol, presence: true
    validates :funding_time, presence: true
    validates :funding_rate, presence: true
  end
end
