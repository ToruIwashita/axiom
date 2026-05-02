module Api
  module V1
    # 02_§4.10 + Q-2C(EquityCurve サーバー側 sampling)+ 軽微 8(pluck 化)
    class BacktestingRunEquityCurveController < ApplicationController
      DEFAULT_SAMPLE_SIZE = 1000
      MAX_SAMPLE_SIZE = 10_000
      private_constant :DEFAULT_SAMPLE_SIZE, :MAX_SAMPLE_SIZE

      def show
        run = Backtesting::Run.find(params[:backtesting_run_id])
        sample_size = (params[:sample_size] || DEFAULT_SAMPLE_SIZE).to_i.clamp(1, MAX_SAMPLE_SIZE)
        rows = sampled_rows(run, sample_size)
        render json: { points: rows.map { |row| row_payload(row) } }
      rescue ActiveRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end

      private

      # 軽微 8: AR インスタンス化を避け pluck で生 Array<Array> を返す。
      # 数万レコードでもメモリ圧迫を抑える。
      def sampled_rows(run, sample_size)
        scope = run.equity_curve_points.order(:ts)
        total = scope.count
        all_rows = scope.pluck(:ts, :equity, :drawdown, :position_size)
        return all_rows if total <= sample_size

        every_n = (total.to_f / sample_size).ceil
        all_rows.each_with_index.select { |_, i| (i % every_n).zero? }.map(&:first)
      end

      def row_payload(row)
        ts, equity, drawdown, position_size = row
        {
          ts: ts.iso8601,
          equity: equity.to_s,
          drawdown: drawdown&.to_s,
          position_size: position_size.to_s
        }
      end
    end
  end
end
