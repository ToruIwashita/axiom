require "bigdecimal"

module Domain
  # バックテスト結果の収益指標を保持する不変オブジェクト
  #
  # @note Rails 非依存実装(子プロセス lib/backtest_runner_child.rb から
  #   require_relative で読込可能とするため)。BigDecimal は標準ライブラリで使用可能。
  class PnLMetricsValueObject
    attr_reader :win_rate, :total_pnl, :max_drawdown, :sharpe_ratio, :sortino_ratio,
                :volatility, :profit_factor, :total_trades, :avg_holding_seconds

    # @param win_rate [BigDecimal] 勝率(0.0〜1.0)
    # @param total_pnl [BigDecimal] 総損益
    # @param max_drawdown [BigDecimal] 最大ドローダウン率
    # @param sharpe_ratio [BigDecimal] シャープレシオ
    # @param sortino_ratio [BigDecimal] ソルティーノレシオ
    # @param volatility [BigDecimal] ボラティリティ
    # @param profit_factor [BigDecimal] プロフィットファクター
    # @param total_trades [Integer] 総トレード数
    # @param avg_holding_seconds [Integer] 平均保有秒数
    def initialize(win_rate:, total_pnl:, max_drawdown:, sharpe_ratio:, sortino_ratio:,
                   volatility:, profit_factor:, total_trades:, avg_holding_seconds:)
      @win_rate = win_rate
      @total_pnl = total_pnl
      @max_drawdown = max_drawdown
      @sharpe_ratio = sharpe_ratio
      @sortino_ratio = sortino_ratio
      @volatility = volatility
      @profit_factor = profit_factor
      @total_trades = total_trades
      @avg_holding_seconds = avg_holding_seconds
    end

    # Hash 形式に変換する(Backtesting::Metrics への保存用)
    #
    # @return [Hash{Symbol => Object}]
    def to_h
      {
        win_rate:, total_pnl:, max_drawdown:, sharpe_ratio:, sortino_ratio:,
        volatility:, profit_factor:, total_trades:, avg_holding_seconds:
      }
    end
  end
end
