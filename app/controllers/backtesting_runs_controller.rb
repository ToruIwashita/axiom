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
    # Phase 3 末 multi-agent review 2 周目 高 R3 反映:
    # 親 Hash 自体が nil の場合の NoMethodError → 500 を防ぐため Strong Parameters で require.
    bt_params = params.require(:backtesting_run)
    run = service.enqueue_backtest(
      definition_id: @definition.id,
      strategy_revision_id: bt_params[:strategy_revision_id].to_i,
      risk_policy_id: bt_params[:risk_policy_id].to_i,
      symbol: bt_params[:symbol],
      granularity: bt_params[:granularity],
      period_from: Time.parse(bt_params[:period_from].to_s),
      period_to: Time.parse(bt_params[:period_to].to_s),
      fee_rate: BigDecimal(bt_params[:fee_rate].to_s),
      slippage_rate: BigDecimal(bt_params[:slippage_rate].to_s),
      include_funding_rate: bt_params[:include_funding_rate] == "1",
      use_mark_basis: bt_params[:use_mark_basis] == "1",
      use_spot_basis: bt_params[:use_spot_basis] == "1"
    )
    redirect_to backtesting_run_path(run), notice: "Enqueued"
  rescue ActiveRecord::RecordNotFound => e
    redirect_to strategy_definition_path(@definition), alert: e.message
  rescue ArgumentError, ActionController::ParameterMissing => e
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

  # Phase 4.3 multi-agent review followup(code-reviewer 高-1):
  # BacktestingRunService#list の :from / :to filter を controller から到達可能にする.
  # Dashboard / Comparison 画面の期間絞り込みで利用される.
  def list_filters
    raw = params.permit(:strategy_definition_id, :status, :from, :to).to_h.symbolize_keys
    raw[:from] = Time.parse(raw[:from]) if raw[:from].present?
    raw[:to] = Time.parse(raw[:to]) if raw[:to].present?
    raw
  end
end
