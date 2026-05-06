module Exchange
  class Order < ApplicationRecord
    self.table_name = "exchange_orders"

    class InvalidTransitionError < StandardError; end

    STATUSES = %w[pending placed partially_filled filled cancelled rejected].freeze
    TERMINAL_STATUSES = %w[filled cancelled rejected].freeze
    SIDES = %w[long short].freeze
    TRADE_SIDES = %w[open close].freeze
    ORDER_TYPES = %w[limit market].freeze
    FORCES = %w[gtc ioc fok post_only].freeze

    private_constant :TERMINAL_STATUSES

    enum :status, STATUSES.index_with(&:itself), prefix: :state
    enum :side, SIDES.index_with(&:itself), prefix: :side
    enum :trade_side, TRADE_SIDES.index_with(&:itself), prefix: :trade_side
    enum :order_type, ORDER_TYPES.index_with(&:itself), prefix: :order_type
    enum :force, FORCES.index_with(&:itself), prefix: :force

    belongs_to :live_trading_trade, class_name: "LiveTrading::Trade"
    belongs_to :strategy_revision, class_name: "Strategy::Revision"

    validates :symbol, presence: true, length: { maximum: 32 }
    validates :side, presence: true
    validates :trade_side, presence: true
    validates :order_type, presence: true
    validates :size, presence: true, numericality: { greater_than: 0 }
    validates :status, presence: true
    validates :force, presence: true
    validates :client_oid, presence: true, uniqueness: true, length: { maximum: 64 }
    validates :bitget_order_id, uniqueness: true, allow_nil: true

    before_validation :ensure_client_oid

    # pending → placed 遷移(Bitget place-order 成功時)
    #
    # @param bitget_order_id [String] Bitget が返した order_id
    # @param placed_at [Time] 発注時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] pending 以外から呼ばれた場合
    def mark_placed!(bitget_order_id:, placed_at:)
      raise InvalidTransitionError, "cannot mark_placed! from status=#{status}" unless state_pending?

      update!(status: "placed", bitget_order_id:, placed_at:)
    end

    # placed → partially_filled 遷移(WS push: 部分約定)
    #
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] placed 以外から呼ばれた場合
    def mark_partially_filled!
      raise InvalidTransitionError, "cannot mark_partially_filled! from status=#{status}" unless state_placed?

      update!(status: "partially_filled")
    end

    # placed / partially_filled → filled 遷移(全約定完了)
    #
    # @param finished_at [Time] 約定完了時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] placed / partially_filled 以外から呼ばれた場合
    def mark_filled!(finished_at:)
      unless state_placed? || state_partially_filled?
        raise InvalidTransitionError, "cannot mark_filled! from status=#{status}"
      end

      update!(status: "filled", finished_at:)
    end

    # placed / partially_filled → cancelled 遷移(キャンセル成功)
    # 終端状態(filled/cancelled/rejected)からの再遷移は冪等性ガードで block
    #
    # @param finished_at [Time] キャンセル完了時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] 終端状態から呼ばれた場合
    def mark_cancelled!(finished_at:)
      raise InvalidTransitionError, "cannot mark_cancelled! from terminal status=#{status}" if terminal?

      update!(status: "cancelled", finished_at:)
    end

    # pending / placed → rejected 遷移(取引所拒否)
    #
    # @param finished_at [Time] 拒否時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] pending / placed 以外から呼ばれた場合
    def mark_rejected!(finished_at:)
      unless state_pending? || state_placed?
        raise InvalidTransitionError, "cannot mark_rejected! from status=#{status}"
      end

      update!(status: "rejected", finished_at:)
    end

    # 終端状態(filled/cancelled/rejected)か判定する
    #
    # @return [Boolean]
    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    private

    # client_oid 冪等性キーの自動生成(明示指定時は保持)
    def ensure_client_oid
      self.client_oid ||= SecureRandom.uuid
    end
  end
end
