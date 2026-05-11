module Api
  module V1
    # LiveTrading::Session の REST API endpoint(02_§6.2.2.2 / Phase 3.4b Step 3.4-5).
    # CRUD(index / show / create)+ stop / emergency_stop は後続 Step 3.4-6 で追加予定.
    class LiveTradingSessionsController < ApplicationController
      include PayloadHelpers

      def index
        sessions = LiveTrading::Session.order(id: :desc)
        render json: { sessions: sessions.map { |s| live_trading_session_payload(s) } }
      end

      def show
        session = LiveTrading::Session.find(params[:id].to_i)
        render json: live_trading_session_payload(session)
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end

      def create
        session = service.start_session(
          strategy_definition_id: params[:strategy_definition_id].to_i,
          strategy_revision_id: params[:strategy_revision_id].to_i,
          risk_policy_id: params[:risk_policy_id].to_i,
          symbol: params[:symbol],
          leverage: params[:leverage].to_i,
          margin_mode: params[:margin_mode],
          position_mode: params[:position_mode],
          asset_mode: params[:asset_mode],
          margin_coin: params[:margin_coin],
          emergency_stop_mode: params[:emergency_stop_mode]
        )
        render json: live_trading_session_payload(session), status: :created
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      rescue ArgumentError => e
        # 整合検証失敗(strategy_definition_id mismatch)→ 400
        # 受入条件不合格(not acceptable for live / uses_live_forbidden_input)→ 422
        if e.message.include?("strategy_definition_id mismatch")
          render json: { error: e.message }, status: :bad_request
        else
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end

      private

      def service
        @service ||= ApplicationServices::LiveTradingSessionService.new
      end
    end
  end
end
