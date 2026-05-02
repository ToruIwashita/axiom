require "bigdecimal"
require "bigdecimal/math"

module Domain
  # バックテスト結果の収益指標を計算する純粋ドメインサービス
  #
  # @note Rails 機能を使わず、状態を持たない純粋関数として動作する。
  #   親プロセス側からのみ呼ばれる(子プロセス側は不要)。
  class StrategyEvaluatorService
    # BigMath.sqrt の精度桁数(重要 4: BigDecimal 統一)
    BIGDECIMAL_PRECISION = 16
    private_constant :BIGDECIMAL_PRECISION

    # trades と equity_curve から PnLMetrics を算出する
    #
    # @param trades [Array<Hash>] {entry_at, exit_at, side, entry_price, exit_price, quantity, pnl} の配列
    # @param equity_curve [Array<Hash>] {ts, equity, drawdown, position_size} の配列
    # @return [Domain::PnLMetricsValueObject]
    def evaluate(trades:, equity_curve: [])
      total_trades = trades.size
      winning_count = trades.count { |t| BigDecimal(t[:pnl].to_s).positive? }
      win_rate = total_trades.zero? ? BigDecimal("0") : BigDecimal(winning_count) / BigDecimal(total_trades)

      total_pnl = trades.sum(BigDecimal("0")) { |t| BigDecimal(t[:pnl].to_s) }
      max_drawdown = calc_max_drawdown(equity_curve)
      daily_pnls = calc_daily_pnls(trades)
      mean = daily_pnls.empty? ? BigDecimal("0") : daily_pnls.sum / BigDecimal(daily_pnls.size)
      volatility = calc_std(daily_pnls, mean)
      sharpe = volatility.zero? ? BigDecimal("0") : mean / volatility
      downside_std = calc_std(daily_pnls.select(&:negative?), BigDecimal("0"))
      sortino = downside_std.zero? ? BigDecimal("0") : mean / downside_std
      profit_factor = calc_profit_factor(trades)
      avg_holding_seconds = calc_avg_holding_seconds(trades)

      Domain::PnLMetricsValueObject.new(
        win_rate:,
        total_pnl:,
        max_drawdown:,
        sharpe_ratio: sharpe,
        sortino_ratio: sortino,
        volatility:,
        profit_factor:,
        total_trades:,
        avg_holding_seconds:
      )
    end

    private

    # 最大ドローダウン率を計算する
    #
    # @param equity_curve [Array<Hash>] {ts, equity, ...} の配列
    # @return [BigDecimal] 0.0〜1.0 の比率(空配列なら 0)
    def calc_max_drawdown(equity_curve)
      return BigDecimal("0") if equity_curve.empty?

      peak = BigDecimal("0")
      max_dd = BigDecimal("0")
      equity_curve.each do |point|
        eq = BigDecimal(point[:equity].to_s)
        peak = eq if eq > peak
        next if peak.zero?

        dd = (peak - eq) / peak
        max_dd = dd if dd > max_dd
      end
      max_dd
    end

    # trades を exit_at の日付ごとに集計した日次 pnl 配列を返す
    #
    # @param trades [Array<Hash>]
    # @return [Array<BigDecimal>] 日次 pnl(順序非依存)
    def calc_daily_pnls(trades)
      grouped = trades.group_by { |t| t[:exit_at].to_date }
      grouped.values.map do |day_trades|
        day_trades.sum(BigDecimal("0")) { |t| BigDecimal(t[:pnl].to_s) }
      end
    end

    # 標準偏差を BigMath.sqrt で計算する(重要 4: BigDecimal 統一)
    #
    # @param values [Array<BigDecimal>]
    # @param mean [BigDecimal]
    # @return [BigDecimal] N-1 母分散の平方根、size < 2 なら 0
    def calc_std(values, mean)
      return BigDecimal("0") if values.size < 2

      variance = values.sum(BigDecimal("0")) { |v| (v - mean) ** 2 } / BigDecimal(values.size - 1)
      BigMath.sqrt(variance, BIGDECIMAL_PRECISION)
    end

    # プロフィットファクター(勝ち pnl 合計 / 負け pnl 絶対値合計)を計算する
    #
    # @param trades [Array<Hash>]
    # @return [BigDecimal] 損失が 0 なら 0(無限大の代替)
    def calc_profit_factor(trades)
      gains = trades.sum(BigDecimal("0")) do |t|
        pnl = BigDecimal(t[:pnl].to_s)
        pnl.positive? ? pnl : BigDecimal("0")
      end
      losses = trades.sum(BigDecimal("0")) do |t|
        pnl = BigDecimal(t[:pnl].to_s)
        pnl.negative? ? pnl.abs : BigDecimal("0")
      end
      return BigDecimal("0") if losses.zero?

      gains / losses
    end

    # 平均保有秒数を計算する
    #
    # @param trades [Array<Hash>]
    # @return [Integer] 空配列なら 0
    def calc_avg_holding_seconds(trades)
      return 0 if trades.empty?

      total_seconds = trades.sum { |t| (t[:exit_at] - t[:entry_at]).to_i }
      total_seconds / trades.size
    end
  end
end
