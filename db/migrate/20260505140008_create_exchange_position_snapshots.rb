class CreateExchangePositionSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :exchange_position_snapshots do |t|
      t.references :live_trading_session, null: false, foreign_key: true
      t.string :margin_coin, limit: 16, null: false
      t.string :symbol, limit: 32, null: false
      t.string :hold_side, limit: 8, null: false
      t.decimal :margin_size, precision: 30, scale: 12
      t.integer :leverage
      t.string :margin_mode, limit: 16
      t.string :pos_mode, limit: 16
      t.string :asset_mode, limit: 16
      t.decimal :open_price_avg, precision: 30, scale: 12
      t.decimal :break_even_price, precision: 30, scale: 12
      t.decimal :mark_price, precision: 30, scale: 12
      t.decimal :total, precision: 30, scale: 12, null: false
      t.decimal :available, precision: 30, scale: 12
      t.decimal :frozen_size, precision: 30, scale: 12
      t.decimal :unrealized_pl, precision: 30, scale: 12
      t.decimal :unrealized_plr, precision: 30, scale: 12
      t.decimal :liquidation_price, precision: 30, scale: 12
      t.decimal :keep_margin_rate, precision: 30, scale: 12
      t.decimal :margin_rate, precision: 30, scale: 12
      t.decimal :total_fee, precision: 30, scale: 12
      t.decimal :deducted_fee, precision: 30, scale: 12
      t.boolean :auto_margin, null: false, default: false
      t.datetime :snapshot_at, null: false
      t.timestamps

      t.index [ :live_trading_session_id, :snapshot_at ],
              name: "idx_exchange_pos_snapshots_session_snapshot_at"
    end
  end
end
