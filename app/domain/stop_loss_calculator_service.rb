module Domain
  # TP / SL 価格計算の Domain サービス(設計書 04_§修正2 + 02_§3.3.4)
  # Bitget の `presetStopSurplusPrice` / `presetStopLossPrice` 委託を前提とした Decimal 価格を返す
  # stateless 純粋関数群
  class StopLossCalculatorService
    SUPPORTED_SIDES = %i[long short].freeze

    private_constant :SUPPORTED_SIDES

    # Take-Profit 価格を計算する
    # long: entry_price * (1 + tp_pct) / short: entry_price * (1 - tp_pct)
    #
    # @param entry_price [BigDecimal] エントリー価格
    # @param side [Symbol] :long / :short
    # @param tp_pct [BigDecimal] TP 比率(例: 0.02 = 2%)
    # @return [BigDecimal] TP 価格
    # @raise [ArgumentError] 未対応 side の場合(fail-fast)
    def calculate_tp(entry_price:, side:, tp_pct:)
      assert_side!(side)

      case side
      when :long
        entry_price * (BigDecimal("1") + tp_pct)
      when :short
        entry_price * (BigDecimal("1") - tp_pct)
      end
    end

    # Stop-Loss 価格を計算する
    # long: entry_price * (1 - sl_pct) / short: entry_price * (1 + sl_pct)
    #
    # @param entry_price [BigDecimal] エントリー価格
    # @param side [Symbol] :long / :short
    # @param sl_pct [BigDecimal] SL 比率(例: 0.02 = 2%)
    # @return [BigDecimal] SL 価格
    # @raise [ArgumentError] 未対応 side の場合(fail-fast)
    def calculate_sl(entry_price:, side:, sl_pct:)
      assert_side!(side)

      case side
      when :long
        entry_price * (BigDecimal("1") - sl_pct)
      when :short
        entry_price * (BigDecimal("1") + sl_pct)
      end
    end

    private

    def assert_side!(side)
      return if SUPPORTED_SIDES.include?(side)

      raise ArgumentError, "unsupported side: #{side.inspect} (must be :long or :short)"
    end
  end
end
