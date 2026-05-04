class BacktestingRunsController < ApplicationController
  def index
    @runs = service.list(filters: list_filters)
  end

  def show
    @run = service.get(run_id: params[:id].to_i)
    @metrics = @run.metrics
    @trades = @run.trades.order(:entry_at) if @run.state_completed?
  rescue ActiveRecord::RecordNotFound
    redirect_to backtesting_runs_path, alert: "Backtesting::Run not found"
  end

  def new
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    # 軽微 12 反映: バックテスト実行可能(acceptable_for_backtest?)な Revision のみ select 候補
    @available_revisions = @definition.revisions
                                       .order(revision_number: :desc)
                                       .select(&:acceptable_for_backtest?)
    @available_risk_policies = Risk::Policy.order(:name)
    @form_defaults = {
      strategy_revision_id: params[:strategy_revision_id].presence,
      symbol: "BTCUSDT",
      granularity: "1H",
      period_from: 1.month.ago.utc.beginning_of_day.iso8601,
      period_to: Time.current.utc.beginning_of_day.iso8601,
      fee_rate: "0.001",
      slippage_rate: "0.0005",
      include_funding_rate: false,
      use_mark_basis: false,
      use_spot_basis: false
    }
  rescue ActiveRecord::RecordNotFound
    redirect_to strategy_definitions_path, alert: "Strategy::Definition not found"
  end

  def create
    @definition = definition_service.get(definition_id: params[:strategy_definition_id].to_i)
    run = service.enqueue_backtest(
      definition_id: @definition.id,
      strategy_revision_id: params[:backtesting_run][:strategy_revision_id].to_i,
      risk_policy_id: params[:backtesting_run][:risk_policy_id].to_i,
      symbol: params[:backtesting_run][:symbol],
      granularity: params[:backtesting_run][:granularity],
      period_from: Time.parse(params[:backtesting_run][:period_from]),
      period_to: Time.parse(params[:backtesting_run][:period_to]),
      fee_rate: BigDecimal(params[:backtesting_run][:fee_rate].to_s),
      slippage_rate: BigDecimal(params[:backtesting_run][:slippage_rate].to_s),
      include_funding_rate: params[:backtesting_run][:include_funding_rate] == "1",
      use_mark_basis: params[:backtesting_run][:use_mark_basis] == "1",
      use_spot_basis: params[:backtesting_run][:use_spot_basis] == "1"
    )
    redirect_to backtesting_run_path(run), notice: "Enqueued"
  rescue ActiveRecord::RecordNotFound => e
    redirect_to strategy_definition_path(@definition), alert: e.message
  rescue ArgumentError => e
    redirect_to new_strategy_definition_backtesting_run_path(@definition), alert: e.message
  end

  def cancel
    @run = service.cancel(run_id: params[:id].to_i)
    redirect_to backtesting_run_path(@run), notice: "Cancelled"
  rescue ActiveRecord::RecordNotFound
    redirect_to backtesting_runs_path, alert: "Backtesting::Run not found"
  end

  private

  def service
    @service ||= ApplicationServices::BacktestingRunService.new
  end

  def definition_service
    @definition_service ||= ApplicationServices::StrategyDefinitionService.new
  end

  def list_filters
    params.permit(:strategy_definition_id, :status).to_h.symbolize_keys
  end
end
