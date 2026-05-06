module Domain
  # ポジションサイズ計算の Domain サービス(設計書 04_§修正2 + 02_§3.3.3)
  # 3 種類のサイジング方式を純粋関数として提供する
  class PositionSizerService
    # ATR ベース: balance * risk_pct * leverage / atr
    # ボラティリティ(ATR)が大きいほど小さいサイズになる
    #
    # @param balance [BigDecimal] 現在残高
    # @param atr [BigDecimal] Average True Range(0 の場合は nil 返却で防衛)
    # @param risk_pct [BigDecimal] 口座資金に対するリスク比率(例: 0.01 = 1%)
    # @param leverage [Integer] レバレッジ倍率
    # @return [BigDecimal, nil] サイズ,atr が 0 の場合は nil
    def calculate_atr_based(balance:, atr:, risk_pct:, leverage:)
      return nil if atr.zero?

      balance * risk_pct * BigDecimal(leverage) / atr
    end

    # 固定サイズ: 指定値をそのまま返す
    #
    # @param size [BigDecimal] 固定サイズ
    # @return [BigDecimal]
    def calculate_fixed(size:)
      size
    end

    # 割合ベース: balance * ratio * leverage
    # 口座残高に対する固定比率でサイジング
    #
    # @param balance [BigDecimal] 現在残高
    # @param ratio [BigDecimal] 口座資金に対する比率(例: 0.05 = 5%)
    # @param leverage [Integer] レバレッジ倍率
    # @return [BigDecimal]
    def calculate_proportional(balance:, ratio:, leverage:)
      balance * ratio * BigDecimal(leverage)
    end
  end
end
