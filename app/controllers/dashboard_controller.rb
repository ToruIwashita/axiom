class DashboardController < ApplicationController
  def show
    service = Domain::DashboardMetricsService.new
    @cumulative_pnl = service.cumulative_pnl
    @uptime_seconds = service.uptime_seconds
    @per_strategy_summary = service.per_strategy_summary
  end
end
