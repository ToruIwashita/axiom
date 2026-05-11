# 軽微 10 対応(02_§0.4 / §4.8.1):
# Plain Hash + render json: 方針(ユーザー方針 U-2 jbuilder 不採用)を全
# Controller で DRY に実現するための共通 concern.
#
# 各 Api::V1::* Controller で `include PayloadHelpers` し,
# `run_payload(run)` 等の private メソッドとして再利用する.
#
# 軽微 11 対応: datetime は .iso8601 で文字列化(Time#as_json 暗黙仕様
# 依存を排除)し,decimal は to_s で文字列化(JSON 数値精度問題回避)する.
module PayloadHelpers
  extend ActiveSupport::Concern

  private

  # @param time [Time, nil]
  # @return [String, nil]
  def serialize_datetime(time)
    time&.iso8601
  end

  # @param value [BigDecimal, Numeric, nil]
  # @return [String, nil]
  def serialize_decimal(value)
    value&.to_s
  end

  def run_payload(run)
    payload = {
      id: run.id,
      strategy_definition_id: run.strategy_definition_id,
      strategy_revision_id: run.strategy_revision_id,
      risk_policy_id: run.risk_policy_id,
      symbol: run.symbol,
      granularity: run.granularity,
      period_from: serialize_datetime(run.period_from),
      period_to: serialize_datetime(run.period_to),
      fee_rate: serialize_decimal(run.fee_rate),
      slippage_rate: serialize_decimal(run.slippage_rate),
      include_funding_rate: run.include_funding_rate,
      use_mark_basis: run.use_mark_basis,
      use_spot_basis: run.use_spot_basis,
      status: run.status,
      failure_reason: run.failure_reason,
      started_at: serialize_datetime(run.started_at),
      finished_at: serialize_datetime(run.finished_at),
      created_at: serialize_datetime(run.created_at),
      updated_at: serialize_datetime(run.updated_at)
    }
    payload[:metrics] = metrics_payload(run.metrics) if run.metrics
    payload
  end

  def metrics_payload(metrics)
    {
      win_rate: serialize_decimal(metrics.win_rate),
      total_pnl: serialize_decimal(metrics.total_pnl),
      max_drawdown: serialize_decimal(metrics.max_drawdown),
      sharpe_ratio: serialize_decimal(metrics.sharpe_ratio),
      sortino_ratio: serialize_decimal(metrics.sortino_ratio),
      volatility: serialize_decimal(metrics.volatility),
      profit_factor: serialize_decimal(metrics.profit_factor),
      total_trades: metrics.total_trades,
      avg_holding_seconds: metrics.avg_holding_seconds
    }
  end

  def trade_payload(trade)
    {
      id: trade.id,
      side: trade.side,
      entry_at: serialize_datetime(trade.entry_at),
      exit_at: serialize_datetime(trade.exit_at),
      entry_price: serialize_decimal(trade.entry_price),
      exit_price: serialize_decimal(trade.exit_price),
      quantity: serialize_decimal(trade.quantity),
      pnl: serialize_decimal(trade.pnl)
    }
  end

  def definition_payload(definition)
    {
      id: definition.id,
      name: definition.name,
      description: definition.description,
      market_type: definition.market_type,
      status: definition.status,
      created_at: serialize_datetime(definition.created_at),
      updated_at: serialize_datetime(definition.updated_at)
    }
  end

  # Phase 3.4b Step 3.4-8: Exchange::Order payload
  def exchange_order_payload(order)
    {
      id: order.id,
      live_trading_trade_id: order.live_trading_trade_id,
      strategy_revision_id: order.strategy_revision_id,
      symbol: order.symbol,
      side: order.side,
      trade_side: order.trade_side,
      order_type: order.order_type,
      size: serialize_decimal(order.size),
      price: serialize_decimal(order.price),
      status: order.status,
      force: order.force,
      reduce_only: order.reduce_only,
      client_oid: order.client_oid,
      bitget_order_id: order.bitget_order_id,
      placed_at: serialize_datetime(order.placed_at),
      finished_at: serialize_datetime(order.finished_at),
      created_at: serialize_datetime(order.created_at),
      updated_at: serialize_datetime(order.updated_at)
    }
  end

  # Phase 3.4b Step 3.4-8: Exchange::AlgoOrder payload
  def exchange_algo_order_payload(algo)
    {
      id: algo.id,
      live_trading_trade_id: algo.live_trading_trade_id,
      strategy_revision_id: algo.strategy_revision_id,
      algo_type: algo.algo_type,
      bitget_algo_id: algo.bitget_algo_id,
      trigger_price: serialize_decimal(algo.trigger_price),
      execute_price: serialize_decimal(algo.execute_price),
      callback_ratio: serialize_decimal(algo.callback_ratio),
      status: algo.status,
      created_at: serialize_datetime(algo.created_at),
      updated_at: serialize_datetime(algo.updated_at)
    }
  end

  # Phase 3.4b Step 3.4-8: Exchange::Fill payload
  def exchange_fill_payload(fill)
    {
      id: fill.id,
      exchange_order_id: fill.exchange_order_id,
      bitget_fill_id: fill.bitget_fill_id,
      price: serialize_decimal(fill.price),
      size: serialize_decimal(fill.size),
      fee: serialize_decimal(fill.fee),
      fee_coin: fill.fee_coin,
      filled_at: serialize_datetime(fill.filled_at),
      created_at: serialize_datetime(fill.created_at),
      updated_at: serialize_datetime(fill.updated_at)
    }
  end

  # Phase 3.4b Step 3.4-7: LiveTrading::Trade payload
  def live_trading_trade_payload(trade)
    {
      id: trade.id,
      live_trading_session_id: trade.live_trading_session_id,
      strategy_revision_id: trade.strategy_revision_id,
      symbol: trade.symbol,
      side: trade.side,
      quantity: serialize_decimal(trade.quantity),
      status: trade.status,
      entry_price: serialize_decimal(trade.entry_price),
      entry_at: serialize_datetime(trade.entry_at),
      exit_price: serialize_decimal(trade.exit_price),
      exit_at: serialize_datetime(trade.exit_at),
      realized_pnl: serialize_decimal(trade.realized_pnl),
      failure_reason: trade.failure_reason,
      created_at: serialize_datetime(trade.created_at),
      updated_at: serialize_datetime(trade.updated_at)
    }
  end

  # Phase 3.4b Step 3.4-7: Exchange::PositionSnapshot payload
  def position_snapshot_payload(snapshot)
    {
      id: snapshot.id,
      live_trading_session_id: snapshot.live_trading_session_id,
      symbol: snapshot.symbol,
      margin_coin: snapshot.margin_coin,
      hold_side: snapshot.hold_side,
      total: serialize_decimal(snapshot.total),
      available: serialize_decimal(snapshot.available),
      frozen_size: serialize_decimal(snapshot.frozen_size),
      open_price_avg: serialize_decimal(snapshot.open_price_avg),
      mark_price: serialize_decimal(snapshot.mark_price),
      break_even_price: serialize_decimal(snapshot.break_even_price),
      liquidation_price: serialize_decimal(snapshot.liquidation_price),
      unrealized_pl: serialize_decimal(snapshot.unrealized_pl),
      unrealized_plr: serialize_decimal(snapshot.unrealized_plr),
      margin_size: serialize_decimal(snapshot.margin_size),
      margin_rate: serialize_decimal(snapshot.margin_rate),
      keep_margin_rate: serialize_decimal(snapshot.keep_margin_rate),
      total_fee: serialize_decimal(snapshot.total_fee),
      deducted_fee: serialize_decimal(snapshot.deducted_fee),
      leverage: snapshot.leverage,
      margin_mode: snapshot.margin_mode,
      pos_mode: snapshot.pos_mode,
      asset_mode: snapshot.asset_mode,
      auto_margin: snapshot.auto_margin,
      snapshot_at: serialize_datetime(snapshot.snapshot_at),
      created_at: serialize_datetime(snapshot.created_at),
      updated_at: serialize_datetime(snapshot.updated_at)
    }
  end

  # Phase 3.4b Step 3.4-5: LiveTrading::Session payload
  def live_trading_session_payload(session)
    {
      id: session.id,
      strategy_definition_id: session.strategy_definition_id,
      strategy_revision_id: session.strategy_revision_id,
      risk_policy_id: session.risk_policy_id,
      symbol: session.symbol,
      leverage: session.leverage,
      margin_mode: session.margin_mode,
      position_mode: session.position_mode,
      asset_mode: session.asset_mode,
      margin_coin: session.margin_coin,
      emergency_stop_mode: session.emergency_stop_mode,
      status: session.status,
      worker_instance_id: session.worker_instance_id,
      failure_reason: session.failure_reason,
      started_at: serialize_datetime(session.started_at),
      stopped_at: serialize_datetime(session.stopped_at),
      created_at: serialize_datetime(session.created_at),
      updated_at: serialize_datetime(session.updated_at)
    }
  end

  def revision_payload(revision)
    {
      id: revision.id,
      strategy_definition_id: revision.strategy_definition_id,
      revision_number: revision.revision_number,
      status: revision.status,
      ast_validation_status: revision.ast_validation_status,
      ast_validation_report: revision.ast_validation_report,
      uses_live_forbidden_input: revision.uses_live_forbidden_input,
      script_entrypoint: revision.script_entrypoint,
      script_checksum: revision.script_checksum,
      ai_filter_enabled: revision.ai_filter_enabled,
      ai_filter_template_name: revision.ai_filter_template_name,
      ai_filter_fail_safe: revision.ai_filter_fail_safe,
      ai_filter_timeout_sec: revision.ai_filter_timeout_sec,
      ai_sizing_enabled: revision.ai_sizing_enabled,
      approved_at: serialize_datetime(revision.approved_at),
      created_at: serialize_datetime(revision.created_at),
      updated_at: serialize_datetime(revision.updated_at)
    }
  end
end
