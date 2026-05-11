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
