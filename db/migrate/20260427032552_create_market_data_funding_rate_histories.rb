class CreateMarketDataFundingRateHistories < ActiveRecord::Migration[8.1]
  def change
    create_table :market_data_funding_rate_histories do |t|
      t.string :symbol, limit: 32, null: false
      t.datetime :funding_time, null: false
      t.decimal :funding_rate, precision: 12, scale: 8, null: false
      t.datetime :created_at, null: false
    end
    add_index :market_data_funding_rate_histories, [ :symbol, :funding_time ], unique: true
  end
end
