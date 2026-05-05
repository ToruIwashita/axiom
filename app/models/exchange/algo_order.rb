module Exchange
  class AlgoOrder < ApplicationRecord
    self.table_name = "exchange_algo_orders"

    ALGO_TYPES = %w[tp sl trailing trigger].freeze
    STATUSES = %w[pending triggered cancelled].freeze

    enum :algo_type, ALGO_TYPES.index_with(&:itself), prefix: :algo_type
    enum :status, STATUSES.index_with(&:itself), prefix: :state

    belongs_to :live_trading_trade, class_name: "LiveTrading::Trade"
    belongs_to :strategy_revision, class_name: "Strategy::Revision"

    validates :algo_type, presence: true
    validates :bitget_algo_id, presence: true, uniqueness: true, length: { maximum: 64 }
    validates :trigger_price, presence: true, numericality: { greater_than: 0 }
    validates :status, presence: true

    # pending → triggered 遷移(WS orders-algo: トリガー到達)
    #
    # @param execute_price [BigDecimal] 約定価格
    # @return [Boolean] update! の結果
    def mark_triggered!(execute_price:)
      update!(status: "triggered", execute_price:)
    end

    # pending → cancelled 遷移(キャンセル成功)
    #
    # @return [Boolean] update! の結果
    def mark_cancelled!
      update!(status: "cancelled")
    end
  end
end
