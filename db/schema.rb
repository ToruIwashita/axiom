# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_27_032552) do
  create_table "market_data_funding_rate_histories", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "funding_rate", precision: 12, scale: 8, null: false
    t.datetime "funding_time", null: false
    t.string "symbol", limit: 32, null: false
    t.index ["symbol", "funding_time"], name: "idx_on_symbol_funding_time_5496f59fa9", unique: true
  end

  create_table "market_data_futures_candles", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.decimal "base_volume", precision: 24, scale: 8
    t.decimal "close", precision: 24, scale: 8, null: false
    t.datetime "created_at", null: false
    t.string "granularity", limit: 16, null: false
    t.decimal "high", precision: 24, scale: 8, null: false
    t.decimal "low", precision: 24, scale: 8, null: false
    t.decimal "open", precision: 24, scale: 8, null: false
    t.decimal "quote_volume", precision: 24, scale: 8
    t.string "symbol", limit: 32, null: false
    t.datetime "ts", null: false
    t.index ["symbol", "granularity", "ts"], name: "idx_on_symbol_granularity_ts_54dc471ada", unique: true
  end

  create_table "market_data_index_candles", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.decimal "close", precision: 24, scale: 8, null: false
    t.datetime "created_at", null: false
    t.string "granularity", limit: 16, null: false
    t.decimal "high", precision: 24, scale: 8, null: false
    t.decimal "low", precision: 24, scale: 8, null: false
    t.decimal "open", precision: 24, scale: 8, null: false
    t.string "symbol", limit: 32, null: false
    t.datetime "ts", null: false
    t.index ["symbol", "granularity", "ts"], name: "idx_on_symbol_granularity_ts_73e0563f93", unique: true
  end

  create_table "market_data_mark_candles", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.decimal "close", precision: 24, scale: 8, null: false
    t.datetime "created_at", null: false
    t.string "granularity", limit: 16, null: false
    t.decimal "high", precision: 24, scale: 8, null: false
    t.decimal "low", precision: 24, scale: 8, null: false
    t.decimal "open", precision: 24, scale: 8, null: false
    t.string "symbol", limit: 32, null: false
    t.datetime "ts", null: false
    t.index ["symbol", "granularity", "ts"], name: "idx_on_symbol_granularity_ts_71a4edf2f8", unique: true
  end

  create_table "market_data_spot_candles", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.decimal "base_volume", precision: 24, scale: 8
    t.decimal "close", precision: 24, scale: 8, null: false
    t.datetime "created_at", null: false
    t.string "granularity", limit: 16, null: false
    t.decimal "high", precision: 24, scale: 8, null: false
    t.decimal "low", precision: 24, scale: 8, null: false
    t.decimal "open", precision: 24, scale: 8, null: false
    t.decimal "quote_volume", precision: 24, scale: 8
    t.string "symbol", limit: 32, null: false
    t.datetime "ts", null: false
    t.index ["symbol", "granularity", "ts"], name: "idx_on_symbol_granularity_ts_901ca45d76", unique: true
  end
end
