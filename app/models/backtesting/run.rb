module Backtesting
  class Run < ApplicationRecord
    self.table_name = "backtesting_runs"

    class InvalidTransitionError < StandardError; end

    STATUSES = %w[pending running completed failed cancelled].freeze
    TERMINAL_STATUSES = %w[completed failed cancelled].freeze
    FAILURE_REASON_MAX_LENGTH = 10_000

    private_constant :TERMINAL_STATUSES, :FAILURE_REASON_MAX_LENGTH

    enum :status, STATUSES.index_with(&:itself), prefix: :state

    # Q-2B 反映(02_§5.5): status 変更時に Turbo Streams で UI へ broadcast
    # `backtesting_run_<id>_status` 要素を _status_badge partial で置換する.
    # Sidekiq Job(BacktestExecutionJob)からの run.start! / run.complete! /
    # run.fail! / run.cancel! 呼出時に発火する.polling controller(Step 3-6)
    # は Action Cable 切断時の fallback として併用.
    after_update_commit -> {
      broadcast_replace_to "backtesting_run_#{id}",
                           target: "backtesting_run_#{id}_status",
                           partial: "backtesting_runs/status_badge",
                           locals: { run: self }
    }

    belongs_to :strategy_definition, class_name: "Strategy::Definition"
    belongs_to :strategy_revision, class_name: "Strategy::Revision"
    belongs_to :risk_policy, class_name: "Risk::Policy"
    has_one :metrics,
            class_name: "Backtesting::Metrics",
            foreign_key: :backtesting_run_id,
            inverse_of: :run,
            dependent: :destroy
    has_many :trades,
             class_name: "Backtesting::Trade",
             foreign_key: :backtesting_run_id,
             dependent: :destroy
    has_many :equity_curve_points,
             class_name: "Backtesting::EquityCurvePoint",
             foreign_key: :backtesting_run_id,
             dependent: :destroy

    validates :symbol, presence: true, length: { maximum: 32 }
    validates :granularity, presence: true, length: { maximum: 16 }
    validates :period_from, presence: true
    validates :period_to, presence: true
    validates :fee_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :slippage_rate, presence: true, numericality: { greater_than_or_equal_to: 0 }
    validates :status, presence: true
    validate :period_to_after_period_from

    # Run を running 状態に遷移する
    #
    # @param started_at [Time] 実行開始時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] pending 以外からの遷移時
    def start!(started_at: Time.current)
      raise InvalidTransitionError, "cannot start! from status=#{status}" unless state_pending?

      update!(status: "running", started_at:)
    end

    # Run を completed 状態に遷移する
    #
    # @param finished_at [Time] 実行終了時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] running 以外からの遷移時
    def complete!(finished_at: Time.current)
      raise InvalidTransitionError, "cannot complete! from status=#{status}" unless state_running?

      update!(status: "completed", finished_at:)
    end

    # Run を failed 状態に遷移する
    #
    # @param failure_reason [String] 失敗理由(10_000 文字を超える場合は truncate)
    # @param finished_at [Time] 実行終了時刻
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] terminal 状態(completed/failed/cancelled)からの遷移時
    def fail!(failure_reason:, finished_at: Time.current)
      raise InvalidTransitionError, "cannot fail! from status=#{status}" if terminal?

      update!(
        status: "failed",
        failure_reason: failure_reason.to_s.truncate(FAILURE_REASON_MAX_LENGTH),
        finished_at:
      )
    end

    # Run を cancelled 状態に遷移する
    #
    # @return [Boolean] update! の結果
    # @raise [InvalidTransitionError] terminal 状態(completed/failed/cancelled)からの遷移時
    def cancel!
      raise InvalidTransitionError, "cannot cancel! from status=#{status}" if terminal?

      update!(status: "cancelled")
    end

    # 終端状態か判定する
    #
    # @return [Boolean] completed / failed / cancelled なら true
    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    private

    def period_to_after_period_from
      return if period_from.blank? || period_to.blank?

      errors.add(:period_to, "must be after period_from") unless period_to > period_from
    end
  end
end
