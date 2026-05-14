module Integration
  # Phase 4.1: Integration::AiInvocationLog 可視化 UI Controller.
  # 設計書 03_§9.4 + 02_§2.4-2.5.
  class AiInvocationLogsController < ApplicationController
    # GET /integration/ai_invocation_logs
    def index
      @logs = service.list(filters: list_filters).page(params[:page]).per(50)
      @context_types = ::Integration::AiInvocationLog::CONTEXT_TYPES
      @statuses = ::Integration::AiInvocationLog::STATUSES
      @selected_context_type = params[:context_type]
      @selected_status = params[:status]
    end

    # GET /integration/ai_invocation_logs/:id
    def show
      @log = service.get(log_id: params[:id].to_i)
    rescue ActiveRecord::RecordNotFound
      redirect_to integration_ai_invocation_logs_path, alert: "ログが見つかりませんでした"
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
