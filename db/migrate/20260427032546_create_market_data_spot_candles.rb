class CreateMarketDataSpotCandles < ActiveRecord::Migration[8.1]
  def change
    create_table :market_data_spot_candles do |t|
      t.string :symbol, limit: 32, null: false
      t.string :granularity, limit: 16, null: false
      t.datetime :ts, null: false
      t.decimal :open, precision: 24, scale: 8, null: false
      t.decimal :high, precision: 24, scale: 8, null: false
      t.decimal :low, precision: 24, scale: 8, null: false
      t.decimal :close, precision: 24, scale: 8, null: false
      t.decimal :base_volume, precision: 24, scale: 8
      t.decimal :quote_volume, precision: 24, scale: 8
      t.datetime :created_at, null: false
    end
    add_index :market_data_spot_candles, [ :symbol, :granularity, :ts ], unique: true
  end
end
