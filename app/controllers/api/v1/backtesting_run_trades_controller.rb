module Api
  module V1
    class BacktestingRunTradesController < ApplicationController
      include PayloadHelpers

      def index
        # Phase 4.3 で Api::V1::Backtesting namespace を追加したため,
        # `Backtesting::` が `Api::V1::Backtesting::` を先に解決して衝突する.
        # トップレベル明示の `::Backtesting::Run` で参照する.
        run = ::Backtesting::Run.find(params[:backtesting_run_id])
        trades = run.trades.order(:entry_at)
        render json: { trades: trades.map { |t| trade_payload(t) } }
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end
    end
  end
end
