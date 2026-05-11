module Api
  module V1
    # 指定 LiveTrading::Session の Trade 一覧 API(02_§6.2.2.3 / Phase 3.4b Step 3.4-7).
    class LiveTradingSessionTradesController < ApplicationController
      include PayloadHelpers

      def index
        session = LiveTrading::Session.find(params[:live_trading_session_id].to_i)
        trades = LiveTrading::Trade.where(live_trading_session_id: session.id).order(id: :desc)
        render json: { trades: trades.map { |t| live_trading_trade_payload(t) } }
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end
    end
  end
end
