module Backtesting
  # バックテスト比較 UI(Phase 4.3 / 02_§4.4).
  # viewmodel 方針: DB 永続化なし / new で Run 選択 → show で結果表示.
  class ComparisonsController < ApplicationController
    def new
      @runs = ::Backtesting::Run.where(status: "completed").order(id: :desc).limit(50)
    end

    def show
      run_ids = Array(params[:run_ids]).map(&:to_i).reject(&:zero?)
      if run_ids.empty?
        redirect_to backtesting_new_comparison_path, alert: "比較対象の Run を 1 件以上選択してください"
        return
      end

      service = Domain::BacktestComparisonService.new(run_ids: run_ids)
      @metrics_table = service.metrics_table
      @parameter_diff = service.parameter_diff
      @run_ids = run_ids
    end
  end
end
