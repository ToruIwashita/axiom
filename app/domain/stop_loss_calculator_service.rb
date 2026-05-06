module Domain
  # TP / SL 価格計算の Domain サービス(設計書 04_§修正2 + 02_§3.3.4)
  # Bitget の `presetStopSurplusPrice` / `presetStopLossPrice` 委託を前提とした Decimal 価格を返す
  # stateless 純粋関数群
  # Phase 3.1 レビュー R-8 反映: tp_pct / sl_pct の範囲を [0, 1) に強制(負価格生成防止)
  class StopLossCalculatorService
    SUPPORTED_SIDES = %i[long short].freeze

    private_constant :SUPPORTED_SIDES

    # Take-Profit 価格を計算する
    # long: entry_price * (1 + tp_pct) / short: entry_price * (1 - tp_pct)
    #
    # @param entry_price [BigDecimal] エントリー価格
    # @param side [Symbol] :long / :short
    # @param tp_pct [BigDecimal] TP 比率(0 以上 1 未満,例: 0.02 = 2%)
    # @return [BigDecimal] TP 価格
    # @raise [ArgumentError] 未対応 side / tp_pct が範囲外の場合(fail-fast)
    def calculate_tp(entry_price:, side:, tp_pct:)
      assert_side!(side)
      assert_pct_range!(:tp_pct, tp_pct)

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
    # @param sl_pct [BigDecimal] SL 比率(0 以上 1 未満,例: 0.02 = 2%)
    # @return [BigDecimal] SL 価格
    # @raise [ArgumentError] 未対応 side / sl_pct が範囲外の場合(fail-fast)
    def calculate_sl(entry_price:, side:, sl_pct:)
      assert_side!(side)
      assert_pct_range!(:sl_pct, sl_pct)

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

    # tp_pct / sl_pct は [0, 1) の範囲のみ受理
    # 1 以上で long の SL / short の TP が負価格になる(物理的にあり得ない)
    def assert_pct_range!(name, pct)
      return if pct >= 0 && pct < 1

      raise ArgumentError, "#{name} must be in [0, 1) (got #{pct.inspect})"
    end
  end
end
