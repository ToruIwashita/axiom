module Api
  module V1
    # LiveTrading::Trade 単体詳細取得 API(02_§6.2.2.5 / Phase 3.4b Step 3.4-8).
    # Trade + 紐付く Order[] + AlgoOrder[] + Fill[] を nested Hash で返却する.
    class LiveTradingTradesController < ApplicationController
      include PayloadHelpers

      def show
        trade = LiveTrading::Trade.find(params[:id].to_i)
        orders = Exchange::Order.where(live_trading_trade_id: trade.id).order(id: :asc).to_a
        algo_orders = Exchange::AlgoOrder.where(live_trading_trade_id: trade.id).order(id: :asc)
        fills = Exchange::Fill.where(exchange_order_id: orders.map(&:id)).order(id: :asc)

        render json: {
          trade: live_trading_trade_payload(trade),
          orders: orders.map { |o| exchange_order_payload(o) },
          algo_orders: algo_orders.map { |a| exchange_algo_order_payload(a) },
          fills: fills.map { |f| exchange_fill_payload(f) }
        }
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end
    end
  end
end
