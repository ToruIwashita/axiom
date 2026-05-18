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

ActiveRecord::Schema[8.1].define(version: 2026_05_19_000001) do
  create_table "backtesting_equity_curve_points", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "backtesting_run_id", null: false
    t.datetime "created_at", null: false
    t.decimal "drawdown", precision: 24, scale: 8
    t.decimal "equity", precision: 24, scale: 8, null: false
    t.decimal "position_size", precision: 24, scale: 8, null: false
    t.datetime "ts", null: false
    t.datetime "updated_at", null: false
    t.index ["backtesting_run_id", "ts"], name: "idx_equity_curve_run_ts"
    t.index ["backtesting_run_id"], name: "index_backtesting_equity_curve_points_on_backtesting_run_id"
  end

  create_table "backtesting_metrics", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.integer "avg_holding_seconds", null: false
    t.bigint "backtesting_run_id", null: false
    t.datetime "created_at", null: false
    t.decimal "max_drawdown", precision: 24, scale: 8, null: false
    t.decimal "profit_factor", precision: 12, scale: 6, null: false
    t.decimal "sharpe_ratio", precision: 12, scale: 6, null: false
    t.decimal "sortino_ratio", precision: 12, scale: 6, null: false
    t.decimal "total_pnl", precision: 24, scale: 8, null: false
    t.integer "total_trades", null: false
    t.datetime "updated_at", null: false
    t.decimal "volatility", precision: 12, scale: 6, null: false
    t.decimal "win_rate", precision: 6, scale: 4, null: false
    t.index ["backtesting_run_id"], name: "index_backtesting_metrics_on_backtesting_run_id", unique: true
  end

  create_table "backtesting_runs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "failure_reason"
    t.decimal "fee_rate", precision: 8, scale: 6, null: false
    t.datetime "finished_at"
    t.string "granularity", limit: 16, null: false
    t.boolean "include_funding_rate", default: false, null: false
    t.datetime "period_from", null: false
    t.datetime "period_to", null: false
    t.bigint "risk_policy_id", null: false
    t.decimal "slippage_rate", precision: 8, scale: 6, null: false
    t.datetime "started_at"
    t.string "status", limit: 32, null: false
    t.bigint "strategy_definition_id", null: false
    t.bigint "strategy_revision_id", null: false
    t.string "symbol", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.boolean "use_mark_basis", default: false, null: false
    t.boolean "use_spot_basis", default: false, null: false
    t.index ["risk_policy_id"], name: "index_backtesting_runs_on_risk_policy_id"
    t.index ["status"], name: "index_backtesting_runs_on_status"
    t.index ["strategy_definition_id"], name: "index_backtesting_runs_on_strategy_definition_id"
    t.index ["strategy_revision_id"], name: "index_backtesting_runs_on_strategy_revision_id"
  end

  create_table "backtesting_trades", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "backtesting_run_id", null: false
    t.datetime "created_at", null: false
    t.datetime "entry_at", null: false
    t.decimal "entry_price", precision: 24, scale: 8, null: false
    t.datetime "exit_at", null: false
    t.decimal "exit_price", precision: 24, scale: 8, null: false
    t.decimal "pnl", precision: 24, scale: 8, null: false
    t.decimal "quantity", precision: 24, scale: 8, null: false
    t.string "side", limit: 8, null: false
    t.datetime "updated_at", null: false
    t.index ["backtesting_run_id"], name: "index_backtesting_trades_on_backtesting_run_id"
  end

  create_table "exchange_algo_orders", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "algo_type", limit: 16, null: false
    t.string "bitget_algo_id", limit: 64, null: false
    t.decimal "callback_ratio", precision: 8, scale: 6
    t.datetime "created_at", null: false
    t.decimal "execute_price", precision: 30, scale: 12
    t.bigint "live_trading_trade_id", null: false
    t.string "status", limit: 16, null: false
    t.bigint "strategy_revision_id", null: false
    t.decimal "trigger_price", precision: 30, scale: 12, null: false
    t.datetime "updated_at", null: false
    t.index ["bitget_algo_id"], name: "index_exchange_algo_orders_on_bitget_algo_id", unique: true
    t.index ["live_trading_trade_id"], name: "index_exchange_algo_orders_on_live_trading_trade_id"
    t.index ["status"], name: "index_exchange_algo_orders_on_status"
    t.index ["strategy_revision_id"], name: "index_exchange_algo_orders_on_strategy_revision_id"
  end

  create_table "exchange_fills", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "bitget_fill_id", limit: 64, null: false
    t.datetime "created_at", null: false
    t.bigint "exchange_order_id", null: false
    t.decimal "fee", precision: 30, scale: 12, null: false
    t.string "fee_coin", limit: 16, null: false
    t.datetime "filled_at", null: false
    t.decimal "price", precision: 30, scale: 12, null: false
    t.decimal "size", precision: 30, scale: 12, null: false
    t.datetime "updated_at", null: false
    t.index ["bitget_fill_id"], name: "index_exchange_fills_on_bitget_fill_id", unique: true
    t.index ["exchange_order_id"], name: "index_exchange_fills_on_exchange_order_id"
  end

  create_table "exchange_orders", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "bitget_order_id", limit: 64
    t.string "client_oid", limit: 64, null: false
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "force", limit: 16, null: false
    t.bigint "live_trading_trade_id", null: false
    t.string "order_type", limit: 8, null: false
    t.datetime "placed_at"
    t.decimal "price", precision: 30, scale: 12
    t.boolean "reduce_only", default: false, null: false
    t.string "side", limit: 8, null: false
    t.decimal "size", precision: 30, scale: 12, null: false
    t.string "status", limit: 32, null: false
    t.bigint "strategy_revision_id", null: false
    t.string "symbol", limit: 32, null: false
    t.string "trade_side", limit: 8, null: false
    t.datetime "updated_at", null: false
    t.index ["bitget_order_id"], name: "index_exchange_orders_on_bitget_order_id", unique: true
    t.index ["client_oid"], name: "index_exchange_orders_on_client_oid", unique: true
    t.index ["live_trading_trade_id"], name: "index_exchange_orders_on_live_trading_trade_id"
    t.index ["status"], name: "index_exchange_orders_on_status"
    t.index ["strategy_revision_id"], name: "index_exchange_orders_on_strategy_revision_id"
  end

  create_table "exchange_position_snapshots", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "asset_mode", limit: 16
    t.boolean "auto_margin", default: false, null: false
    t.decimal "available", precision: 30, scale: 12
    t.decimal "break_even_price", precision: 30, scale: 12
    t.datetime "created_at", null: false
    t.decimal "deducted_fee", precision: 30, scale: 12
    t.decimal "frozen_size", precision: 30, scale: 12
    t.string "hold_side", limit: 8, null: false
    t.decimal "keep_margin_rate", precision: 30, scale: 12
    t.integer "leverage"
    t.decimal "liquidation_price", precision: 30, scale: 12
    t.bigint "live_trading_session_id", null: false
    t.string "margin_coin", limit: 16, null: false
    t.string "margin_mode", limit: 16
    t.decimal "margin_rate", precision: 30, scale: 12
    t.decimal "margin_size", precision: 30, scale: 12
    t.decimal "mark_price", precision: 30, scale: 12
    t.decimal "open_price_avg", precision: 30, scale: 12
    t.string "pos_mode", limit: 16
    t.datetime "snapshot_at", null: false
    t.string "symbol", limit: 32, null: false
    t.decimal "total", precision: 30, scale: 12, null: false
    t.decimal "total_fee", precision: 30, scale: 12
    t.decimal "unrealized_pl", precision: 30, scale: 12
    t.decimal "unrealized_plr", precision: 30, scale: 12
    t.datetime "updated_at", null: false
    t.index ["live_trading_session_id", "snapshot_at"], name: "idx_exchange_pos_snapshots_session_snapshot_at"
    t.index ["live_trading_session_id"], name: "index_exchange_position_snapshots_on_live_trading_session_id"
  end

  create_table "integration_ai_invocation_logs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "context_type", limit: 32, null: false
    t.datetime "created_at", null: false
    t.integer "latency_ms", null: false
    t.text "prompt"
    t.text "response"
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["context_type"], name: "index_integration_ai_invocation_logs_on_context_type"
    t.index ["status"], name: "index_integration_ai_invocation_logs_on_status"
  end

  create_table "live_trading_session_heartbeats", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "live_trading_session_id", null: false
    t.datetime "pulsed_at", null: false
    t.datetime "updated_at", null: false
    t.string "worker_instance_id", limit: 64, null: false
    t.index ["live_trading_session_id", "pulsed_at"], name: "idx_lt_heartbeats_session_pulsed_at"
    t.index ["live_trading_session_id"], name: "idx_on_live_trading_session_id_92c820e151"
  end

  create_table "live_trading_session_leases", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "acquired_at", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "lease_token", limit: 64, null: false
    t.bigint "live_trading_session_id", null: false
    t.datetime "renewed_at"
    t.string "status", limit: 16, null: false
    t.datetime "updated_at", null: false
    t.string "worker_instance_id", limit: 64, null: false
    t.index ["lease_token"], name: "index_live_trading_session_leases_on_lease_token", unique: true
    t.index ["live_trading_session_id"], name: "index_live_trading_session_leases_on_live_trading_session_id", unique: true
    t.index ["status"], name: "index_live_trading_session_leases_on_status"
  end

  create_table "live_trading_session_states", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "live_trading_session_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.json "state_data", null: false
    t.datetime "updated_at", null: false
    t.index ["live_trading_session_id"], name: "index_live_trading_session_states_on_live_trading_session_id", unique: true
  end

  create_table "live_trading_sessions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "asset_mode", limit: 16, null: false
    t.datetime "created_at", null: false
    t.string "emergency_stop_mode", limit: 32, null: false
    t.text "failure_reason"
    t.integer "leverage", null: false
    t.string "margin_coin", limit: 16, null: false
    t.string "margin_mode", limit: 16, null: false
    t.string "position_mode", limit: 16, null: false
    t.bigint "risk_policy_id", null: false
    t.datetime "started_at"
    t.string "status", limit: 32, null: false
    t.datetime "stopped_at"
    t.bigint "strategy_definition_id", null: false
    t.bigint "strategy_revision_id", null: false
    t.string "symbol", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.string "worker_instance_id", limit: 64
    t.index ["risk_policy_id"], name: "index_live_trading_sessions_on_risk_policy_id"
    t.index ["status"], name: "index_live_trading_sessions_on_status"
    t.index ["strategy_definition_id"], name: "index_live_trading_sessions_on_strategy_definition_id"
    t.index ["strategy_revision_id"], name: "index_live_trading_sessions_on_strategy_revision_id"
    t.index ["symbol"], name: "index_live_trading_sessions_on_symbol"
  end

  create_table "live_trading_trades", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "entry_at"
    t.decimal "entry_price", precision: 30, scale: 12
    t.datetime "exit_at"
    t.decimal "exit_price", precision: 30, scale: 12
    t.text "failure_reason"
    t.bigint "live_trading_session_id", null: false
    t.decimal "quantity", precision: 30, scale: 12, null: false
    t.decimal "realized_pnl", precision: 30, scale: 12
    t.string "side", limit: 8, null: false
    t.decimal "sl_pct", precision: 30, scale: 12
    t.string "status", limit: 16, null: false
    t.bigint "strategy_revision_id", null: false
    t.string "symbol", limit: 32, null: false
    t.decimal "tp_pct", precision: 30, scale: 12
    t.datetime "updated_at", null: false
    t.index ["live_trading_session_id"], name: "index_live_trading_trades_on_live_trading_session_id"
    t.index ["status"], name: "index_live_trading_trades_on_status"
    t.index ["strategy_revision_id"], name: "index_live_trading_trades_on_strategy_revision_id"
  end

  create_table "live_trading_ws_metrics", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "delta_private", default: 0, null: false
    t.integer "delta_public", default: 0, null: false
    t.datetime "detected_at", null: false
    t.bigint "live_trading_session_id", null: false
    t.integer "private_count_since_start", default: 0, null: false
    t.integer "public_count_since_start", default: 0, null: false
    t.string "source_event", limit: 32
    t.string "target_ws", limit: 16
    t.datetime "updated_at", null: false
    t.string "worker_instance_id", limit: 64, null: false
    t.index ["live_trading_session_id", "detected_at"], name: "idx_lt_ws_metrics_session_detected_at"
    t.index ["live_trading_session_id", "worker_instance_id", "detected_at"], name: "idx_lt_ws_metrics_session_worker_detected_at"
    t.index ["live_trading_session_id"], name: "index_live_trading_ws_metrics_on_live_trading_session_id"
  end

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

  create_table "risk_policies", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.integer "consecutive_loss_limit", null: false
    t.integer "cooldown_minutes", null: false
    t.datetime "created_at", null: false
    t.decimal "daily_loss_limit_usdt", precision: 20, scale: 8, null: false
    t.decimal "max_drawdown_pct", precision: 5, scale: 2, null: false
    t.integer "max_leverage", null: false
    t.decimal "max_position_exposure_usdt", precision: 20, scale: 8, null: false
    t.string "name", limit: 100, null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_risk_policies_on_name", unique: true
  end

  create_table "strategy_definitions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "market_type", limit: 32, null: false
    t.string "name", null: false
    t.string "status", limit: 32, null: false
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_strategy_definitions_on_status"
  end

  create_table "strategy_revisions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.boolean "ai_filter_enabled", default: false, null: false
    t.string "ai_filter_fail_safe", limit: 16
    t.string "ai_filter_template_name", limit: 128
    t.integer "ai_filter_timeout_sec", default: 10
    t.boolean "ai_sizing_enabled", default: false, null: false
    t.datetime "approved_at"
    t.datetime "archived_at"
    t.text "ast_validation_report"
    t.string "ast_validation_status", limit: 16, null: false
    t.datetime "created_at", null: false
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
    t.index ["status"], name: "index_strategy_revisions_on_status"
    t.index ["strategy_definition_id", "revision_number"], name: "idx_on_strategy_definition_id_revision_number_d06f7a7ac0", unique: true
    t.index ["strategy_definition_id"], name: "index_strategy_revisions_on_strategy_definition_id"
  end

  add_foreign_key "backtesting_equity_curve_points", "backtesting_runs"
  add_foreign_key "backtesting_metrics", "backtesting_runs"
  add_foreign_key "backtesting_runs", "risk_policies"
  add_foreign_key "backtesting_runs", "strategy_definitions"
  add_foreign_key "backtesting_runs", "strategy_revisions"
  add_foreign_key "backtesting_trades", "backtesting_runs"
  add_foreign_key "exchange_algo_orders", "live_trading_trades"
  add_foreign_key "exchange_algo_orders", "strategy_revisions"
  add_foreign_key "exchange_fills", "exchange_orders"
  add_foreign_key "exchange_orders", "live_trading_trades"
  add_foreign_key "exchange_orders", "strategy_revisions"
  add_foreign_key "exchange_position_snapshots", "live_trading_sessions"
  add_foreign_key "live_trading_session_heartbeats", "live_trading_sessions"
  add_foreign_key "live_trading_session_leases", "live_trading_sessions"
  add_foreign_key "live_trading_session_states", "live_trading_sessions"
  add_foreign_key "live_trading_sessions", "risk_policies"
  add_foreign_key "live_trading_sessions", "strategy_definitions"
  add_foreign_key "live_trading_sessions", "strategy_revisions"
  add_foreign_key "live_trading_trades", "live_trading_sessions"
  add_foreign_key "live_trading_trades", "strategy_revisions"
  add_foreign_key "live_trading_ws_metrics", "live_trading_sessions"
  add_foreign_key "strategy_revisions", "strategy_definitions"
end
