module Exchange
  class AlgoOrder < ApplicationRecord
    self.table_name = "exchange_algo_orders"

    class InvalidTransitionError < StandardError; end

    ALGO_TYPES = %w[tp sl trailing trigger].freeze
    STATUSES = %w[pending triggered cancelled].freeze
    TERMINAL_STATUSES = %w[triggered cancelled].freeze

    private_constant :TERMINAL_STATUSES

    enum :algo_type, ALGO_TYPES.index_with(&:itself), prefix: :algo_type
    enum :status, STATUSES.index_with(&:itself), prefix: :state

    belongs_to :live_trading_trade, class_name: "LiveTrading::Trade"
    belongs_to :strategy_revision, class_name: "Strategy::Revision"

    validates :algo_type, presence: true
    validates :bitget_algo_id, presence: true, uniqueness: true, length: { maximum: 64 }
    validates :trigger_price, presence: true, numericality: { greater_than: 0 }
    validates :status, presence: true
    # Phase 3.1 レビュー R-11 反映: trailing 時のみ callback_ratio 必須
    # (Bitget 仕様: presetTrailingPriceRatio は trailing オーダー必須)
    validates :callback_ratio, presence: true, if: :algo_type_trailing?

    # pending → triggered 遷移(WS orders-algo: トリガー到達)
    #
    # @param execute_price [BigDecimal] 約定価格
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] pending 以外から呼ばれた場合
    def mark_triggered!(execute_price:)
      raise InvalidTransitionError, "cannot mark_triggered! from status=#{status}" unless state_pending?

      update!(status: "triggered", execute_price:)
    end

    # pending → cancelled 遷移(キャンセル成功)
    # 終端状態(triggered/cancelled)からの再遷移は冪等性ガードで block
    #
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] 終端状態から呼ばれた場合
    def mark_cancelled!
      raise InvalidTransitionError, "cannot mark_cancelled! from terminal status=#{status}" if terminal?

      update!(status: "cancelled")
    end

    # 終端状態(triggered/cancelled)か判定する
    #
    # @return [Boolean]
    def terminal?
      TERMINAL_STATUSES.include?(status)
    end
  end
end
