module LiveTrading
  class Trade < ApplicationRecord
    self.table_name = "live_trading_trades"

    STATUSES = %w[pending entering open closing closed cancelled failed].freeze
    SIDES = %w[long short].freeze
    FAILURE_REASON_MAX_LENGTH = 10_000

    private_constant :FAILURE_REASON_MAX_LENGTH

    enum :status, STATUSES.index_with(&:itself), prefix: :state
    enum :side, SIDES.index_with(&:itself), prefix: :side

    belongs_to :live_trading_session, class_name: "LiveTrading::Session"
    belongs_to :strategy_revision, class_name: "Strategy::Revision"

    validates :symbol, presence: true, length: { maximum: 32 }
    validates :side, presence: true
    validates :quantity, presence: true, numericality: { greater_than: 0 }
    validates :status, presence: true

    # pending → entering 遷移(エントリー発注時)
    #
    # @return [Boolean] update! の結果
    def start_entering!
      update!(status: "entering")
    end

    # entering → open 遷移(エントリー約定時)
    #
    # @param entry_price [BigDecimal] 約定価格
    # @param entry_at [Time] 約定時刻
    # @return [Boolean] update! の結果
    def mark_open!(entry_price:, entry_at:)
      update!(status: "open", entry_price:, entry_at:)
    end

    # open → closing 遷移(クローズ発注時)
    #
    # @return [Boolean] update! の結果
    def start_closing!
      update!(status: "closing")
    end

    # closing → closed 遷移(クローズ約定時)
    #
    # @param exit_price [BigDecimal] 約定価格
    # @param exit_at [Time] 約定時刻
    # @param realized_pnl [BigDecimal] 確定損益(fee/slippage 反映後)
    # @return [Boolean] update! の結果
    def mark_closed!(exit_price:, exit_at:, realized_pnl:)
      update!(status: "closed", exit_price:, exit_at:, realized_pnl:)
    end

    # 任意状態 → cancelled 遷移(注文キャンセル時)
    #
    # @param reason [String] キャンセル理由
    # @return [Boolean] update! の結果
    def mark_cancelled!(reason:)
      update!(
        status: "cancelled",
        failure_reason: reason.to_s.truncate(FAILURE_REASON_MAX_LENGTH)
      )
    end

    # 任意状態 → failed 遷移(取引所拒否 / 致命エラー時)
    #
    # @param reason [String] 失敗理由(10_000 文字を超える場合は truncate)
    # @return [Boolean] update! の結果
    def mark_failed!(reason:)
      update!(
        status: "failed",
        failure_reason: reason.to_s.truncate(FAILURE_REASON_MAX_LENGTH)
      )
    end
  end
end
