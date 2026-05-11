# Phase 3.4b Step 3.4-12 / 02_§6.2.3.2
# LiveTrading::Trade 単体表示の UI Controller. show のみ.
class LiveTradingTradesController < ApplicationController
  def show
    @trade = LiveTrading::Trade.find(params[:id].to_i)
    @orders = Exchange::Order.where(live_trading_trade_id: @trade.id).order(id: :asc)
    @algo_orders = Exchange::AlgoOrder.where(live_trading_trade_id: @trade.id).order(id: :asc)
    @fills = Exchange::Fill.where(exchange_order_id: @orders.pluck(:id)).order(id: :asc)
  rescue ActiveRecord::RecordNotFound
    redirect_to live_trading_sessions_path, alert: "Trade not found"
  end
end
