module Domain
  # ポジションサイズ計算の Domain サービス(設計書 04_§修正2 + 02_§3.3.3)
  # 3 種類のサイジング方式を純粋関数として提供する
  # Phase 3.1 レビュー R-7 反映: 引数の負値防衛(Fail-Fast)を全メソッドに追加
  class PositionSizerService
    # ATR ベース: balance * risk_pct * leverage / atr
    # ボラティリティ(ATR)が大きいほど小さいサイズになる
    #
    # @param balance [BigDecimal] 現在残高(>= 0)
    # @param atr [BigDecimal] Average True Range(0 以下は nil 返却で防衛)
    # @param risk_pct [BigDecimal] 口座資金に対するリスク比率(>= 0,例: 0.01 = 1%)
    # @param leverage [Integer] レバレッジ倍率(>= 1)
    # @return [BigDecimal, nil] サイズ,atr が 0 以下の場合は nil
    # @raise [ArgumentError] balance / risk_pct が負値,leverage が 0 以下の場合
    def calculate_atr_based(balance:, atr:, risk_pct:, leverage:)
      assert_non_negative!(:balance, balance)
      assert_non_negative!(:risk_pct, risk_pct)
      assert_positive_leverage!(leverage)
      return nil if atr <= 0

      balance * risk_pct * BigDecimal(leverage) / atr
    end

    # 固定サイズ: 指定値をそのまま返す
    #
    # @param size [BigDecimal] 固定サイズ(>= 0)
    # @return [BigDecimal]
    # @raise [ArgumentError] size が負値の場合
    def calculate_fixed(size:)
      assert_non_negative!(:size, size)

      size
    end

    # 割合ベース: balance * ratio * leverage
    # 口座残高に対する固定比率でサイジング
    #
    # @param balance [BigDecimal] 現在残高(>= 0)
    # @param ratio [BigDecimal] 口座資金に対する比率(>= 0,例: 0.05 = 5%)
    # @param leverage [Integer] レバレッジ倍率(>= 1)
    # @return [BigDecimal]
    # @raise [ArgumentError] balance / ratio が負値,leverage が 0 以下の場合
    def calculate_proportional(balance:, ratio:, leverage:)
      assert_non_negative!(:balance, balance)
      assert_non_negative!(:ratio, ratio)
      assert_positive_leverage!(leverage)

      balance * ratio * BigDecimal(leverage)
    end

    private

    def assert_non_negative!(name, value)
      return if value >= 0

      raise ArgumentError, "#{name} must be >= 0 (got #{value.inspect})"
    end

    def assert_positive_leverage!(leverage)
      return if leverage >= 1

      raise ArgumentError, "leverage must be >= 1 (got #{leverage.inspect})"
    end
  end
end
