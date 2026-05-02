require "bigdecimal"

module Domain
  # 仮想ポジションを表す不変オブジェクト
  #
  # @note Rails 非依存実装(子プロセス lib/backtest_runner_child.rb から
  #   require_relative で読込可能とするため)。BigDecimal は標準ライブラリで使用可能。
  class PositionValueObject
    attr_reader :side, :size, :entry_price

    # @param side [Symbol, nil] :long / :short / nil(ノーポジ)
    # @param size [BigDecimal] 数量
    # @param entry_price [BigDecimal] 平均建値
    def initialize(side: nil, size: BigDecimal("0"), entry_price: BigDecimal("0"))
      @side = side
      @size = size
      @entry_price = entry_price
    end

    # ノーポジか判定する
    #
    # @return [Boolean] side が nil または size が 0 なら true
    def flat?
      side.nil? || size.zero?
    end

    # ロングポジションか判定する
    #
    # @return [Boolean] side: :long かつ size が非ゼロなら true
    def long?
      side == :long && !size.zero?
    end

    # ショートポジションか判定する
    #
    # @return [Boolean] side: :short かつ size が非ゼロなら true
    def short?
      side == :short && !size.zero?
    end

    # 含み損益を計算する
    #
    # @param current_price [BigDecimal] 現在価格
    # @return [BigDecimal] 含み損益(フラットポジションは 0)
    def unrealized_pnl(current_price)
      return BigDecimal("0") if flat?

      diff = current_price - entry_price
      diff = -diff if short?
      size * diff
    end
  end
end
