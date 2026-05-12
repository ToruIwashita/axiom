module Api
  module V1
    class BacktestingRunsController < ApplicationController
      include PayloadHelpers

      def index
        runs = service.list(filters: list_filters)
        render json: { runs: runs.map { |r| run_payload(r) } }
      end

      def show
        run = service.get(run_id: params[:id].to_i)
        render json: run_payload(run)
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end

      def create
        run = service.enqueue_backtest(
          definition_id: params[:strategy_definition_id].to_i,
          strategy_revision_id: params[:strategy_revision_id].to_i,
          risk_policy_id: params[:risk_policy_id].to_i,
          symbol: params[:symbol],
          granularity: params[:granularity],
          period_from: Time.parse(params[:period_from].to_s),
          period_to: Time.parse(params[:period_to].to_s),
          fee_rate: BigDecimal(params[:fee_rate].to_s),
          slippage_rate: BigDecimal(params[:slippage_rate].to_s),
          include_funding_rate: params[:include_funding_rate] || false,
          use_mark_basis: params[:use_mark_basis] || false,
          use_spot_basis: params[:use_spot_basis] || false
        )
        render json: run_payload(run), status: :accepted
      rescue ArgumentError => e
        render json: { error: e.message }, status: :bad_request
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end

      def cancel
        run = service.cancel(run_id: params[:id].to_i)
        render json: run_payload(run)
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end

      private

      def service
        @service ||= ApplicationServices::BacktestingRunService.new
      end

      def list_filters
        params.permit(:strategy_definition_id, :status).to_h.symbolize_keys
      end
    end
  end
end
