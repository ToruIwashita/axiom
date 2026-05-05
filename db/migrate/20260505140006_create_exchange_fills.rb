class CreateExchangeFills < ActiveRecord::Migration[8.1]
  def change
    create_table :exchange_fills do |t|
      t.references :exchange_order, null: false, foreign_key: true
      t.string :bitget_fill_id, limit: 64, null: false
      t.decimal :price, precision: 30, scale: 12, null: false
      t.decimal :size, precision: 30, scale: 12, null: false
      t.decimal :fee, precision: 30, scale: 12, null: false
      t.string :fee_coin, limit: 16, null: false
      t.datetime :filled_at, null: false
      t.timestamps

      t.index :bitget_fill_id, unique: true
    end
  end
end
