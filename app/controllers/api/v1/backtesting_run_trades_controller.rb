module Api
  module V1
    class BacktestingRunTradesController < ApplicationController
      include PayloadHelpers

      def index
        run = Backtesting::Run.find(params[:backtesting_run_id])
        trades = run.trades.order(:entry_at)
        render json: { trades: trades.map { |t| trade_payload(t) } }
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end
    end
  end
end
