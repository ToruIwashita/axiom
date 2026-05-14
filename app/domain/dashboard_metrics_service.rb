module Domain
  # 横断ダッシュボード用 metrics 集計 Domain サービス(Phase 4.3).
  #
  # 設計書 02_§4.3 / 03_§4.1.
  #
  # ## 設計上の重要事項
  # - cumulative_pnl: backtesting / live_trading を意味的に分離(`total` フィールドなし / 中-4 反映).
  #   シミュレーション(backtesting)と実取引(live_trading)を単純加算すると誤解を誘発する.
  # - uptime_seconds: `uptime_seconds_total` のみ(8 status 別なし / 中-5 反映).
  #   8 status 別の累積稼働時間は SessionStatusEvent audit log 新設後(Phase 5b)に対応.
  # - per_strategy_summary: group by 4 SQL + Revision/Definition eager load 2 SQL で N+1 回避(新-中-2 反映).
  # - uptime_seconds: pluck + Ruby sum で AR インスタンス化を回避(新-中-3 反映).
  class DashboardMetricsService
    PERIODS = %i[daily weekly monthly].freeze

    def initialize(period: :daily, range: 30.days, clock: Time.method(:current), logger: Rails.logger)
      @period = period
      @range = range
      @clock = clock
      @logger = logger
    end

    # 累積 PnL(中-4 反映: total 削除 / backtesting と live_trading を意味的に分離)
    #
    # @return [Hash{Symbol => BigDecimal}] { backtesting:, live_trading: }
    def cumulative_pnl
      bt_pnl = Backtesting::Metrics.joins(:run)
                                    .where(backtesting_runs: { status: "completed" })
                                    .where("backtesting_runs.finished_at >= ?", since)
                                    .sum(:total_pnl)
      lt_pnl = LiveTrading::Trade.where(status: "closed")
                                  .where("exit_at >= ?", since)
                                  .sum(:realized_pnl)
      {
        backtesting: bt_pnl || BigDecimal("0"),
        live_trading: lt_pnl || BigDecimal("0")
      }
    end

    # 稼働率(中-5 反映: 8 status 別なし / Phase 5b で audit log 新設後に対応).
    # 新-中-3 反映: pluck + Ruby sum で SQL 1 + AR インスタンス化回避.
    #
    # @return [Hash{Symbol => Integer}] { uptime_seconds_total:, period_seconds: }
    def uptime_seconds
      now = clock.call
      rows = LiveTrading::Session.where("started_at >= ?", since)
                                  .pluck(:started_at, :stopped_at)
      total = rows.sum { |started, stopped| ((stopped || now) - started).to_i }
      {
        uptime_seconds_total: total,
        period_seconds: @range.to_i
      }
    end

    # 戦略別成績(新-中-2 反映: group by 4 SQL + eager load 2 SQL で N+1 回避).
    #
    # @return [Array<Hash>] [{ revision_id:, revision_label:, live_pnl:, live_count:, live_wins:, backtest_runs: }]
    def per_strategy_summary
      # multi-agent review followup(中-2): LiveTrading::Trade に直接 strategy_revision_id カラムが
      # あるため joins(:strategy_revision) は冗長(3 INNER JOIN を削減).group(:strategy_revision_id)
      # で直接集計する.
      revisions = Strategy::Revision.includes(:strategy_definition).index_by(&:id)
      base_trades = LiveTrading::Trade.where(status: "closed")
      pnl_by_rev = base_trades.group(:strategy_revision_id).sum(:realized_pnl)
      count_by_rev = base_trades.group(:strategy_revision_id).count
      wins_by_rev = base_trades.where("realized_pnl > 0").group(:strategy_revision_id).count
      bt_runs_by_rev = Backtesting::Run.where(status: "completed").group(:strategy_revision_id).count

      revisions.map do |rev_id, rev|
        {
          revision_id: rev_id,
          revision_label: build_revision_label(rev),
          live_pnl: pnl_by_rev[rev_id] || BigDecimal("0"),
          live_count: count_by_rev[rev_id] || 0,
          live_wins: wins_by_rev[rev_id] || 0,
          backtest_runs: bt_runs_by_rev[rev_id] || 0
        }
      end
    end

    private

    attr_reader :clock, :logger

    def since
      clock.call - @range
    end

    # Strategy::Revision に label カラム / メソッドが未定義のため
    # Strategy::Definition.name + Revision.revision_number から構築する.
    def build_revision_label(rev)
      "#{rev.strategy_definition.name} v#{rev.revision_number}"
    end
  end
end
