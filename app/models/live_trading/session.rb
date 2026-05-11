module LiveTrading
  class Session < ApplicationRecord
    self.table_name = "live_trading_sessions"

    class InvalidTransitionError < StandardError; end

    STATUSES = %w[starting reconciling running cooling_down stopping stopped failed_to_start halted].freeze
    TERMINAL_STATUSES = %w[stopped failed_to_start halted].freeze
    MARGIN_MODES = %w[isolated crossed].freeze
    POSITION_MODES = %w[one_way_mode hedge_mode].freeze
    ASSET_MODES = %w[single union].freeze
    EMERGENCY_STOP_MODES = %w[cancel_only cancel_and_market_close cancel_and_reduce_only].freeze
    FAILURE_REASON_MAX_LENGTH = 10_000
    IMMUTABLE_FK_ATTRS = %w[strategy_definition_id strategy_revision_id risk_policy_id].freeze

    private_constant :TERMINAL_STATUSES, :FAILURE_REASON_MAX_LENGTH, :IMMUTABLE_FK_ATTRS

    enum :status, STATUSES.index_with(&:itself), prefix: :state
    enum :margin_mode, MARGIN_MODES.index_with(&:itself), prefix: :margin
    enum :position_mode, POSITION_MODES.index_with(&:itself), prefix: :position
    enum :asset_mode, ASSET_MODES.index_with(&:itself), prefix: :asset
    enum :emergency_stop_mode, EMERGENCY_STOP_MODES.index_with(&:itself), prefix: :emergency_stop

    # Phase 3.4b Step 3.4-13(02_§6.2.4)反映: status 変更時に Turbo Streams で UI へ broadcast.
    # `live_trading_session_<id>_status` 要素を _status_badge partial で置換する.
    # Worker / ApplicationServices からの状態遷移呼出時に発火する.
    # polling controller(live_trading_status_polling)は Action Cable 切断時の fallback として併用.
    # Phase 3.4b R-12 反映: Backtesting::Run と対称な locals(session: self) で partial に渡す.
    after_update_commit -> {
      broadcast_replace_to "live_trading_session_#{id}",
                           target: "live_trading_session_#{id}_status",
                           partial: "live_trading_sessions/status_badge",
                           locals: { session: self }
    }

    belongs_to :strategy_definition, class_name: "Strategy::Definition"
    belongs_to :strategy_revision, class_name: "Strategy::Revision"
    belongs_to :risk_policy, class_name: "Risk::Policy"

    # Phase 3.1 レビュー R-3 反映: 02_§3.2.1 通りの has_one / has_many 関連 5 件
    has_one :session_lease,
            class_name: "LiveTrading::SessionLease",
            foreign_key: :live_trading_session_id,
            dependent: :destroy
    has_one :session_state,
            class_name: "LiveTrading::SessionState",
            foreign_key: :live_trading_session_id,
            dependent: :destroy
    # 履歴系は delete_all で高速削除(高頻度蓄積のため callback 不要)
    has_many :session_heartbeats,
             class_name: "LiveTrading::SessionHeartbeat",
             foreign_key: :live_trading_session_id,
             dependent: :delete_all
    # Trade は監査追跡性確保のため restrict_with_error
    has_many :trades,
             class_name: "LiveTrading::Trade",
             foreign_key: :live_trading_session_id,
             dependent: :restrict_with_error
    has_many :position_snapshots,
             class_name: "Exchange::PositionSnapshot",
             foreign_key: :live_trading_session_id,
             dependent: :delete_all

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
    # @raise [InvalidTransitionError] starting 以外から呼ばれた場合
    def start_reconciling!
      raise InvalidTransitionError, "cannot start_reconciling! from status=#{status}" unless state_starting?

      update!(status: "reconciling")
    end

    # reconciling / cooling_down → running 遷移
    # cooling_down からの呼出は cooldown 期間経過後の resume を含む
    #
    # @param started_at [Time] 実行開始時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] reconciling / cooling_down 以外から呼ばれた場合
    def start_running!(started_at: Time.current)
      unless state_reconciling? || state_cooling_down?
        raise InvalidTransitionError, "cannot start_running! from status=#{status}"
      end

      update!(status: "running", started_at:)
    end

    # running → cooling_down 遷移(RiskGuard.should_cooldown? trigger)
    #
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] running 以外から呼ばれた場合
    def start_cooling_down!
      raise InvalidTransitionError, "cannot start_cooling_down! from status=#{status}" unless state_running?

      update!(status: "cooling_down")
    end

    # cooling_down → running 遷移(cooldown 期間経過)
    # 内部実装は start_running! に委譲(同一遷移先で重複ロジック回避)
    #
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] cooling_down 以外から呼ばれた場合
    def resume_from_cooling!
      raise InvalidTransitionError, "cannot resume_from_cooling! from status=#{status}" unless state_cooling_down?

      update!(status: "running")
    end

    # running / cooling_down → stopping 遷移(kill-switch 受領)
    #
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] running / cooling_down 以外から呼ばれた場合
    def start_stopping!
      unless state_running? || state_cooling_down?
        raise InvalidTransitionError, "cannot start_stopping! from status=#{status}"
      end

      update!(status: "stopping")
    end

    # stopping → stopped 遷移(全 close 完了)
    #
    # @param stopped_at [Time] 停止完了時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] stopping 以外から呼ばれた場合
    def mark_stopped!(stopped_at: Time.current)
      raise InvalidTransitionError, "cannot mark_stopped! from status=#{status}" unless state_stopping?

      update!(status: "stopped", stopped_at:)
    end

    # 非終端状態 → failed_to_start 遷移(bootstrap step 1-11 失敗時)
    # 終端状態(stopped/failed_to_start/halted)からの再遷移は冪等性ガードで block
    #
    # @param reason [String] 失敗理由(10_000 文字を超える場合は truncate)
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] 終端状態から呼ばれた場合
    def mark_failed_to_start!(reason:)
      raise InvalidTransitionError, "cannot mark_failed_to_start! from terminal status=#{status}" if terminal?

      update!(
        status: "failed_to_start",
        failure_reason: reason.to_s.truncate(FAILURE_REASON_MAX_LENGTH)
      )
    end

    # 非終端状態 → halted 遷移(RiskGuard.should_halt? or 致命エラー / 自動再開なし)
    # 終端状態(stopped/failed_to_start/halted)からの再遷移は冪等性ガードで block
    #
    # @param reason [String] 失敗理由(10_000 文字を超える場合は truncate)
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] 終端状態から呼ばれた場合
    def mark_halted!(reason:)
      raise InvalidTransitionError, "cannot mark_halted! from terminal status=#{status}" if terminal?

      update!(
        status: "halted",
        failure_reason: reason.to_s.truncate(FAILURE_REASON_MAX_LENGTH)
      )
    end

    # 終端状態(stopped/failed_to_start/halted)か判定する
    #
    # @return [Boolean]
    def terminal?
      TERMINAL_STATUSES.include?(status)
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
