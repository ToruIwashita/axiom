module Domain
  # Backtesting::Run 複数比較用 Domain サービス(Phase 4.3).
  #
  # 設計書 02_§4.4 / 03_§4.2.
  #
  # ## 設計上の重要事項
  # - sample_equity_points: 既存 `Api::V1::BacktestingRunEquityCurveController#sampled_rows`
  #   と同アルゴリズム(pluck + every_n 間引き / 中-3 反映)を採用し
  #   AR インスタンス化を回避する.共通化は Phase 5b 引き継ぎ事項(over-engineering 回避).
  # - metrics / strategy_revision は eager load,equity_curve_points は per Run pluck で
  #   メモリと SQL 件数のトレードオフを取る(通常 2-5 件比較なので per Run SQL でも問題なし).
  class BacktestComparisonService
    DEFAULT_SAMPLE_SIZE = 1000

    def initialize(run_ids:, logger: Rails.logger)
      @runs = Backtesting::Run.includes(:metrics, :strategy_revision)
                              .where(id: run_ids)
                              .order(:id)
      @logger = logger
    end

    # 9 項目の metrics を Run 別に返す.
    #
    # @return [Array<Hash>] [{ run_id:, label:, metrics: }]
    def metrics_table
      @runs.map do |run|
        {
          run_id: run.id,
          label: "Run ##{run.id}",
          metrics: run.metrics&.attributes&.slice(
            "win_rate", "total_pnl", "max_drawdown", "sharpe_ratio",
            "sortino_ratio", "volatility", "profit_factor",
            "total_trades", "avg_holding_seconds"
          )
        }
      end
    end

    # equity curve 重ね描き用データ.
    # 中-3 反映: 既存 sampled_rows と同じ pluck + every_n 間引きで AR インスタンス化回避.
    #
    # @param sample_size [Integer]
    # @return [Array<Hash>] [{ run_id:, label:, points: [{ ts:, equity:, drawdown: }, ...] }]
    def equity_curves(sample_size: DEFAULT_SAMPLE_SIZE)
      @runs.map do |run|
        {
          run_id: run.id,
          label: build_label(run),
          points: sample_equity_points(run, sample_size)
        }
      end
    end

    # 6 項目のパラメータを Run 別に返す.
    #
    # @return [Array<Hash>]
    def parameter_diff
      keys = %i[period_from period_to fee_rate slippage_rate risk_policy_id strategy_revision_id]
      @runs.map do |run|
        keys.index_with { |k| run.send(k) }.merge(run_id: run.id)
      end
    end

    private

    attr_reader :logger

    def build_label(run)
      "Run ##{run.id} (#{run.period_from.to_date}〜#{run.period_to.to_date})"
    end

    # 既存 BacktestingRunEquityCurveController#sampled_rows と同アルゴリズム.
    def sample_equity_points(run, sample_size)
      scope = run.equity_curve_points.order(:ts)
      total = scope.count
      all_rows = scope.pluck(:ts, :equity, :drawdown)
      return all_rows.map { |row| serialize_row(row) } if total <= sample_size

      every_n = (total.to_f / sample_size).ceil
      all_rows.each_with_index.select { |_, i| (i % every_n).zero? }.map { |(row, _)| serialize_row(row) }
    end

    def serialize_row(row)
      ts, equity, drawdown = row
      { ts: ts.iso8601, equity: equity.to_s, drawdown: drawdown&.to_s }
    end
  end
end
