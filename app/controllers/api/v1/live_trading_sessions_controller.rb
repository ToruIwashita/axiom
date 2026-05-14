module Api
  module V1
    # LiveTrading::Session の REST API endpoint(02_§6.2.2.2 / Phase 3.4b Step 3.4-5).
    # CRUD(index / show / create)+ stop / emergency_stop は後続 Step 3.4-6 で追加予定.
    class LiveTradingSessionsController < ApplicationController
      include PayloadHelpers

      def index
        # Phase 4.2 + 高-3 反映: bulk_monitor で N+1 回避 + kaminari paginate
        # multi-agent review followup(中-2): bulk_monitor 内で SessionLease を独自取得するため
        # ここでの includes(:session_lease) は使われず無駄な eager load 1 SQL となるため削除
        sessions = LiveTrading::Session.order(id: :desc).page(params[:page]).per(50)
        monitor_map = Domain::SessionMonitorService.bulk_monitor(sessions: sessions)
        render json: {
          sessions: sessions.map { |s| live_trading_session_list_payload(s, monitor_map[s.id]) },
          total: sessions.total_count
        }
      end

      def show
        session = LiveTrading::Session.find(params[:id].to_i)
        # Phase 4.2 + 新-中-5 反映: monitor を memoize して detail payload 経由で渡す
        monitor = Domain::SessionMonitorService.new(session: session)
        render json: live_trading_session_detail_payload(session, monitor)
      rescue ActiveRecord::RecordNotFound
        # Phase 4.1 Agent 3 中-1 同流儀: 内部実装露出回避のため静的メッセージ化
        render json: { error: "live_trading_session not found" }, status: :not_found
      end

      def create
        p = create_params
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

      # Phase 3.4b Step 3.4-6: 単一 session を kill-switch シグナル(stopping 遷移)で停止する.
      # 実際の注文 cancel + position 処理は Worker 側で KillSwitchExecutorService 経由で実行される.
      def stop
        session = service.stop(session_id: params[:id].to_i, mode: params[:mode])
        render json: live_trading_session_payload(session)
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      rescue ArgumentError => e
        render json: { error: e.message }, status: :bad_request
      rescue LiveTrading::Session::InvalidTransitionError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # Phase 3.4b Step 3.4-6: 全 running session を一斉 stopping に遷移させる(緊急停止).
      def emergency_stop
        sessions = service.emergency_stop(mode: params[:mode])
        render json: { sessions: sessions.map { |s| live_trading_session_payload(s) } }
      rescue ArgumentError => e
        render json: { error: e.message }, status: :bad_request
      end

      private

      def service
        @service ||= ApplicationServices::LiveTradingSessionService.new
      end

      # Strong Parameters: create で受け入れる属性を allow-list で限定する.
      # JSON ルート要素として `live_trading_session` で包まれているケースと
      # 直接 top-level に置かれているケースの両方に対応(Phase 2.2 軽微 10 規約整合).
      def create_params
        if params[:live_trading_session].present?
          params.require(:live_trading_session).permit(
            :strategy_definition_id, :strategy_revision_id, :risk_policy_id,
            :symbol, :leverage, :margin_mode, :position_mode, :asset_mode,
            :margin_coin, :emergency_stop_mode
          )
        else
          params.permit(
            :strategy_definition_id, :strategy_revision_id, :risk_policy_id,
            :symbol, :leverage, :margin_mode, :position_mode, :asset_mode,
            :margin_coin, :emergency_stop_mode
          )
        end
      end
    end
  end
end
