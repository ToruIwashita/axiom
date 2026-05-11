module Api
  module V1
    # 指定 LiveTrading::Session の最新 PositionSnapshot API(02_§6.2.2.4 / Phase 3.4b Step 3.4-7).
    class LiveTradingSessionPositionsController < ApplicationController
      include PayloadHelpers

      def show
        session = LiveTrading::Session.find(params[:live_trading_session_id].to_i)
        snapshot = Exchange::PositionSnapshot.latest_for(session.id).first
        if snapshot
          render json: position_snapshot_payload(snapshot)
        else
          # 履歴 0 件は no-position として position: nil で返却
          render json: { position: nil }
        end
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end
    end
  end
end
