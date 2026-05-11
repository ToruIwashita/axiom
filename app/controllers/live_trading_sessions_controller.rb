# Phase 3.4b Step 3.4-9 / 02_§6.2.3.1
# LiveTrading::Session の UI 側 Controller. index / show / new / create を提供.
# stop / emergency_stop は Step 3.4-10 で追加予定.
class LiveTradingSessionsController < ApplicationController
  def index
    @sessions = LiveTrading::Session.order(id: :desc)
  end

  def show
    @session = LiveTrading::Session.find(params[:id].to_i)
  rescue ActiveRecord::RecordNotFound
    redirect_to live_trading_sessions_path, alert: "Session not found"
  end

  def new
    @form_defaults = form_defaults
    @promoted_revisions = Strategy::Revision.where(status: "promoted").order(id: :desc)
    @risk_policies = Risk::Policy.order(id: :desc)
  end

  def create
    p = params.require(:live_trading_session).permit(
      :strategy_definition_id, :strategy_revision_id, :risk_policy_id,
      :symbol, :leverage, :margin_mode, :position_mode, :asset_mode,
      :margin_coin, :emergency_stop_mode
    )
    session = service.start_session(
      strategy_definition_id: p[:strategy_definition_id].to_i,
      strategy_revision_id: p[:strategy_revision_id].to_i,
      risk_policy_id: p[:risk_policy_id].to_i,
      symbol: p[:symbol],
      leverage: p[:leverage].to_i,
      margin_mode: p[:margin_mode],
      position_mode: p[:position_mode],
      asset_mode: p[:asset_mode],
      margin_coin: p[:margin_coin],
      emergency_stop_mode: p[:emergency_stop_mode]
    )
    redirect_to live_trading_session_path(session), notice: "セッションを起動しました"
  rescue ActiveRecord::RecordNotFound => e
    redirect_to live_trading_sessions_path, alert: e.message
  rescue ArgumentError => e
    redirect_to new_live_trading_session_path, alert: e.message
  end

  private

  def service
    @service ||= ApplicationServices::LiveTradingSessionService.new
  end

  def form_defaults
    {
      symbol: "BTCUSDT",
      leverage: 10,
      margin_mode: "isolated",
      position_mode: "one_way_mode",
      asset_mode: "single",
      margin_coin: "USDT",
      emergency_stop_mode: "cancel_only"
    }
  end
end
