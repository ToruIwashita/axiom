module Api
  module V1
    module Integration
      # Phase 4.1: Integration::AiInvocationLog 可視化 API.
      # 設計書 03_§9.4 + 02_§2.4-2.5.
      #
      # peer AI レビュー反映:
      #   - 低-2 反映: list / detail で payload 分離(一覧で 10_000 char 全件転送回避)
      # multi-agent review Agent 2 中-4 反映:
      # `service` / `list_filters` private メソッドは UI Controller(Integration::AiInvocationLogsController)と同実装.
      # 既存 axiom 流儀(BacktestingRunsController 等)で API/UI Controller の責務分離を優先しており,
      # 共通 concern 化は Phase 5b の横断 refactor 候補(他 Controller 群の concern 化と一括対応推奨).
      class AiInvocationLogsController < ApplicationController
        include PayloadHelpers

        # GET /api/v1/integration/ai_invocation_logs
        def index
          logs = service.list(filters: list_filters).page(params[:page]).per(50)
          render json: {
            logs: logs.map { |log| ai_invocation_log_list_payload(log) },
            total: logs.total_count
          }
        rescue ArgumentError => e
          # multi-agent review Agent 2 中-2 反映: enum allow-list 違反は 400
          render json: { error: e.message }, status: :bad_request
        end

        # GET /api/v1/integration/ai_invocation_logs/:id
        # multi-agent review Agent 3 中-1 反映: e.message から内部実装(クラス名)露出を防ぐため静的メッセージ化.
        def show
          log = service.get(log_id: params[:id].to_i)
          render json: ai_invocation_log_detail_payload(log)
        rescue ActiveRecord::RecordNotFound
          render json: { error: "ai_invocation_log not found" }, status: :not_found
        end

        # GET /api/v1/integration/ai_invocation_logs/aggregate
        def aggregate
          render json: service.aggregate
        end

        private

        def service
          @service ||= ApplicationServices::AiInvocationLogService.new
        end

        def list_filters
          params.permit(:context_type, :status).to_h.symbolize_keys
        end
      end
    end
  end
end
