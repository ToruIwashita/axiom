module Api
  module V1
    module Backtesting
      # バックテスト比較 API(Phase 4.3 / 02_§4.4 + §4.6).
      # viewmodel 方針: DB 永続化なし / run_ids[] パラメータで複数 Run を受け取り
      # metrics_table / equity_curves / parameter_diff を JSON 返却.
      class ComparisonsController < ApplicationController
        def show
          run_ids = Array(params[:run_ids]).map(&:to_i).reject(&:zero?)
          if run_ids.empty?
            render json: { error: "run_ids must not be empty" }, status: :bad_request
            return
          end

          service = Domain::BacktestComparisonService.new(run_ids: run_ids)
          render json: {
            metrics_table: service.metrics_table,
            equity_curves: service.equity_curves(sample_size: sample_size_param),
            parameter_diff: service.parameter_diff
          }
        end

        private

        def sample_size_param
          (params[:sample_size] || Domain::BacktestComparisonService::DEFAULT_SAMPLE_SIZE).to_i.clamp(1, 10_000)
        end
      end
    end
  end
end
