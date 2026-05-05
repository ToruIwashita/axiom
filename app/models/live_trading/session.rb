module LiveTrading
  class Session < ApplicationRecord
    self.table_name = "live_trading_sessions"

    class InvalidTransitionError < StandardError; end

    STATUSES = %w[starting reconciling running cooling_down stopping stopped failed_to_start halted].freeze
    MARGIN_MODES = %w[isolated crossed].freeze
    POSITION_MODES = %w[one_way_mode hedge_mode].freeze
    ASSET_MODES = %w[single union].freeze
    EMERGENCY_STOP_MODES = %w[cancel_only cancel_and_market_close cancel_and_reduce_only].freeze
    FAILURE_REASON_MAX_LENGTH = 10_000
    IMMUTABLE_FK_ATTRS = %w[strategy_definition_id strategy_revision_id risk_policy_id].freeze

    private_constant :FAILURE_REASON_MAX_LENGTH, :IMMUTABLE_FK_ATTRS

    enum :status, STATUSES.index_with(&:itself), prefix: :state
    enum :margin_mode, MARGIN_MODES.index_with(&:itself), prefix: :margin
    enum :position_mode, POSITION_MODES.index_with(&:itself), prefix: :position
    enum :asset_mode, ASSET_MODES.index_with(&:itself), prefix: :asset
    enum :emergency_stop_mode, EMERGENCY_STOP_MODES.index_with(&:itself), prefix: :emergency_stop

    belongs_to :strategy_definition, class_name: "Strategy::Definition"
    belongs_to :strategy_revision, class_name: "Strategy::Revision"
    belongs_to :risk_policy, class_name: "Risk::Policy"

    validates :symbol, presence: true, length: { maximum: 32 }
    validates :leverage, presence: true,
                         numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 125 }
    validates :margin_mode, presence: true
    validates :position_mode, presence: true
    validates :asset_mode, presence: true
    validates :margin_coin, presence: true, length: { maximum: 16 }
    validates :emergency_stop_mode, presence: true
    validates :status, presence: true

    validate :forbid_immutable_fk_change

    # starting → reconciling 遷移
    #
    # @return [Boolean] update! の結果
    def start_reconciling!
      update!(status: "reconciling")
    end

    # reconciling → running 遷移
    #
    # @param started_at [Time] 実行開始時刻
    # @return [Boolean] update! の結果
    def start_running!(started_at: Time.current)
      update!(status: "running", started_at:)
    end

    # running → cooling_down 遷移(RiskGuard.should_cooldown? trigger)
    #
    # @return [Boolean] update! の結果
    def start_cooling_down!
      update!(status: "cooling_down")
    end

    # cooling_down → running 遷移(cooldown 期間経過)
    #
    # @return [Boolean] update! の結果
    def resume_from_cooling!
      update!(status: "running")
    end

    # running / cooling_down → stopping 遷移(kill-switch 受領)
    #
    # @return [Boolean] update! の結果
    def start_stopping!
      update!(status: "stopping")
    end

    # stopping → stopped 遷移(全 close 完了)
    #
    # @param stopped_at [Time] 停止完了時刻
    # @return [Boolean] update! の結果
    def mark_stopped!(stopped_at: Time.current)
      update!(status: "stopped", stopped_at:)
    end

    # 任意状態 → failed_to_start 遷移(bootstrap step 1-11 失敗時)
    #
    # @param reason [String] 失敗理由(10_000 文字を超える場合は truncate)
    # @return [Boolean] update! の結果
    def mark_failed_to_start!(reason:)
      update!(
        status: "failed_to_start",
        failure_reason: reason.to_s.truncate(FAILURE_REASON_MAX_LENGTH)
      )
    end

    # 任意状態 → halted 遷移(RiskGuard.should_halt? or 致命エラー / 自動再開なし)
    #
    # @param reason [String] 失敗理由(10_000 文字を超える場合は truncate)
    # @return [Boolean] update! の結果
    def mark_halted!(reason:)
      update!(
        status: "halted",
        failure_reason: reason.to_s.truncate(FAILURE_REASON_MAX_LENGTH)
      )
    end

    private

    # FK 不変参照(設計書 05_§1.1 / §6.6): 永続化後の strategy_definition_id /
    # strategy_revision_id / risk_policy_id 変更を block する
    def forbid_immutable_fk_change
      return unless persisted?

      IMMUTABLE_FK_ATTRS.each do |attr|
        next unless send("#{attr}_changed?")

        errors.add(attr, "cannot be changed after creation")
      end
    end
  end
end
