require "bigdecimal"

module Domain
  # 戦略コードからの発注意図を表す不変オブジェクト
  #
  # @note Rails 非依存実装(子プロセス lib/backtest_runner_child.rb から
  #   require_relative で読込可能とするため)。BigDecimal は標準ライブラリで使用可能。
  class OrderIntentValueObject
    SIDES = %i[long short close].freeze
    ORDER_TYPES = %i[market limit].freeze

    attr_reader :side, :size, :order_type, :limit_price, :tp_pct, :sl_pct

    # @param side [Symbol] :long / :short / :close
    # @param size [BigDecimal] 数量
    # @param order_type [Symbol] :market / :limit(default :market)
    # @param limit_price [BigDecimal, nil] 指値価格(:limit のときのみ必須)
    # @param tp_pct [BigDecimal, nil] 利確率(0.0〜1.0)
    # @param sl_pct [BigDecimal, nil] 損切率(0.0〜1.0)
    # @raise [ArgumentError] side / order_type が許容外、または :limit で limit_price 不在
    def initialize(side:, size:, order_type: :market, limit_price: nil, tp_pct: nil, sl_pct: nil)
      raise ArgumentError, "invalid side: #{side.inspect}" unless SIDES.include?(side)
      raise ArgumentError, "invalid order_type: #{order_type.inspect}" unless ORDER_TYPES.include?(order_type)
      raise ArgumentError, "limit_price required for :limit order" if order_type == :limit && limit_price.nil?

      @side = side
      @size = size
      @order_type = order_type
      @limit_price = limit_price
      @tp_pct = tp_pct
      @sl_pct = sl_pct
    end

    # 成行注文か判定する
    #
    # @return [Boolean]
    def market?
      order_type == :market
    end

    # 指値注文か判定する
    #
    # @return [Boolean]
    def limit?
      order_type == :limit
    end

    # IPC で子プロセスから受信した Hash から VO を構築する
    #
    # @param hash [Hash] 子プロセスからの order_intent Hash
    #   ({ "side" => "long", "size" => "1.0", "order_type" => "market", ... })
    # @return [OrderIntentValueObject]
    def self.from_h(hash)
      new(
        side: hash["side"].to_sym,
        size: BigDecimal(hash["size"].to_s),
        order_type: (hash["order_type"] || "market").to_sym,
        limit_price: hash["limit_price"] && BigDecimal(hash["limit_price"].to_s),
        tp_pct: hash["tp_pct"] && BigDecimal(hash["tp_pct"].to_s),
        sl_pct: hash["sl_pct"] && BigDecimal(hash["sl_pct"].to_s)
      )
    end
  end
end
