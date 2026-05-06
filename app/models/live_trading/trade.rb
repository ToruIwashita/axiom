module LiveTrading
  class Trade < ApplicationRecord
    self.table_name = "live_trading_trades"

    class InvalidTransitionError < StandardError; end

    STATUSES = %w[pending entering open closing closed cancelled failed].freeze
    TERMINAL_STATUSES = %w[closed cancelled failed].freeze
    SIDES = %w[long short].freeze
    FAILURE_REASON_MAX_LENGTH = 10_000

    private_constant :TERMINAL_STATUSES, :FAILURE_REASON_MAX_LENGTH

    enum :status, STATUSES.index_with(&:itself), prefix: :state
    enum :side, SIDES.index_with(&:itself), prefix: :side

    belongs_to :live_trading_session, class_name: "LiveTrading::Session"
    belongs_to :strategy_revision, class_name: "Strategy::Revision"

    validates :symbol, presence: true, length: { maximum: 32 }
    validates :side, presence: true
    validates :quantity, presence: true, numericality: { greater_than: 0 }
    validates :status, presence: true
    # Phase 3.1 レビュー R-5 反映: 価格は正値のみ(Bitget 応答 parsing バグでの負値混入防衛)
    validates :entry_price, numericality: { greater_than: 0 }, allow_nil: true
    validates :exit_price, numericality: { greater_than: 0 }, allow_nil: true

    # pending → entering 遷移(エントリー発注時)
    #
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] pending 以外から呼ばれた場合
    def start_entering!
      raise InvalidTransitionError, "cannot start_entering! from status=#{status}" unless state_pending?

      update!(status: "entering")
    end

    # entering → open 遷移(エントリー約定時)
    #
    # @param entry_price [BigDecimal] 約定価格
    # @param entry_at [Time] 約定時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] entering 以外から呼ばれた場合
    def mark_open!(entry_price:, entry_at:)
      raise InvalidTransitionError, "cannot mark_open! from status=#{status}" unless state_entering?

      update!(status: "open", entry_price:, entry_at:)
    end

    # open → closing 遷移(クローズ発注時)
    #
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] open 以外から呼ばれた場合
    def start_closing!
      raise InvalidTransitionError, "cannot start_closing! from status=#{status}" unless state_open?

      update!(status: "closing")
    end

    # closing → closed 遷移(クローズ約定時)
    #
    # @param exit_price [BigDecimal] 約定価格
    # @param exit_at [Time] 約定時刻
    # @param realized_pnl [BigDecimal] 確定損益(fee/slippage 反映後)
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] closing 以外から呼ばれた場合
    def mark_closed!(exit_price:, exit_at:, realized_pnl:)
      raise InvalidTransitionError, "cannot mark_closed! from status=#{status}" unless state_closing?

      update!(status: "closed", exit_price:, exit_at:, realized_pnl:)
    end

    # 非終端状態 → cancelled 遷移(注文キャンセル時)
    # 終端状態(closed/cancelled/failed)からの再遷移は冪等性ガードで block
    #
    # @param reason [String] キャンセル理由
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] 終端状態から呼ばれた場合
    def mark_cancelled!(reason:)
      raise InvalidTransitionError, "cannot mark_cancelled! from terminal status=#{status}" if terminal?

      update!(
        status: "cancelled",
        failure_reason: reason.to_s.truncate(FAILURE_REASON_MAX_LENGTH)
      )
    end

    # 非終端状態 → failed 遷移(取引所拒否 / 致命エラー時)
    # 終端状態(closed/cancelled/failed)からの再遷移は冪等性ガードで block
    #
    # @param reason [String] 失敗理由(10_000 文字を超える場合は truncate)
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] 終端状態から呼ばれた場合
    def mark_failed!(reason:)
      raise InvalidTransitionError, "cannot mark_failed! from terminal status=#{status}" if terminal?

      update!(
        status: "failed",
        failure_reason: reason.to_s.truncate(FAILURE_REASON_MAX_LENGTH)
      )
    end

    # 終端状態(closed/cancelled/failed)か判定する
    #
    # @return [Boolean]
    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    # realized_pnl が負(損失)か判定する
    # Domain::RiskGuardService#should_cooldown? の連続損失判定で使用される
    #
    # @return [Boolean] realized_pnl が存在し負の値なら true,それ以外 false
    def loss?
      realized_pnl.present? && realized_pnl.negative?
    end
  end
end
