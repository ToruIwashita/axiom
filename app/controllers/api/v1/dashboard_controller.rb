module Api
  module V1
    # 横断ダッシュボード API(Phase 4.3 / 02_§4.3 + §4.6).
    # cumulative_pnl(中-4 反映: total なし)/ uptime_seconds(中-5 反映: total のみ)/
    # per_strategy_summary を JSON で返す.
    class DashboardController < ApplicationController
      def show
        service = Domain::DashboardMetricsService.new
        render json: {
          cumulative_pnl: serialize_pnl(service.cumulative_pnl),
          uptime_seconds: service.uptime_seconds,
          per_strategy_summary: service.per_strategy_summary.map { |s| serialize_summary(s) }
        }
      end

      private

      def serialize_pnl(pnl)
        { backtesting: pnl[:backtesting].to_s, live_trading: pnl[:live_trading].to_s }
      end

      def serialize_summary(summary)
        summary.merge(live_pnl: summary[:live_pnl].to_s)
      end
    end
  end
end
