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

ActiveRecord::Schema[8.1].define(version: 2026_04_29_220634) do
  create_table "market_data_funding_rate_histories", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "funding_rate", precision: 12, scale: 8, null: false
    t.datetime "funding_time", null: false
    t.string "symbol", limit: 32, null: false
    t.index ["symbol", "funding_time"], name: "idx_on_symbol_funding_time_5496f59fa9", unique: true
  end

  create_table "market_data_futures_candles", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
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

  create_table "market_data_index_candles", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
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

  create_table "market_data_mark_candles", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
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

  create_table "market_data_spot_candles", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
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

  create_table "strategy_definitions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "market_type", limit: 32, null: false
    t.string "name", null: false
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["status"], name: "index_strategy_definitions_on_status"
    t.index ["user_id"], name: "index_strategy_definitions_on_user_id"
  end

  create_table "strategy_revisions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.boolean "ai_filter_enabled", default: false, null: false
    t.string "ai_filter_fail_safe", limit: 16
    t.string "ai_filter_template_name", limit: 128
    t.integer "ai_filter_timeout_sec", default: 10
    t.boolean "ai_sizing_enabled", default: false, null: false
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.datetime "archived_at"
    t.text "ast_validation_report"
    t.string "ast_validation_status", limit: 16, null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.datetime "deprecated_at"
    t.datetime "promoted_at"
    t.integer "revision_number", null: false
    t.string "script_checksum", limit: 64, null: false
    t.text "script_content", null: false
    t.string "script_entrypoint", null: false
    t.string "status", limit: 32, null: false
    t.bigint "strategy_definition_id", null: false
    t.datetime "updated_at", null: false
    t.boolean "uses_live_forbidden_input", default: false, null: false
    t.index ["approved_by_id"], name: "index_strategy_revisions_on_approved_by_id"
    t.index ["created_by_id"], name: "index_strategy_revisions_on_created_by_id"
    t.index ["status"], name: "index_strategy_revisions_on_status"
    t.index ["strategy_definition_id", "revision_number"], name: "idx_on_strategy_definition_id_revision_number_d06f7a7ac0", unique: true
    t.index ["strategy_definition_id"], name: "index_strategy_revisions_on_strategy_definition_id"
  end

  create_table "users", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "strategy_definitions", "users"
  add_foreign_key "strategy_revisions", "strategy_definitions"
  add_foreign_key "strategy_revisions", "users", column: "approved_by_id"
  add_foreign_key "strategy_revisions", "users", column: "created_by_id"
end
