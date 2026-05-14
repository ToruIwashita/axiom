module Api
  module V1
    module Integration
      # Phase 4.1: Integration::AiInvocationLog 可視化 API.
      # 設計書 03_§9.4 + 02_§2.4-2.5.
      #
      # peer AI レビュー反映:
      #   - 低-2 反映: list / detail で payload 分離(一覧で 10_000 char 全件転送回避)
      class AiInvocationLogsController < ApplicationController
        include PayloadHelpers

        # GET /api/v1/integration/ai_invocation_logs
        def index
          logs = service.list(filters: list_filters).page(params[:page]).per(50)
          render json: {
            logs: logs.map { |log| ai_invocation_log_list_payload(log) },
            total: logs.total_count
          }
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
