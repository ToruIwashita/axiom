module ApplicationServices
  # Backtesting::Run の enqueue / cancel / 取得 / 一覧ユースケースを提供する
  # アプリケーション層サービス
  #
  # 02_§4.4 の確定仕様に準拠.
  class BacktestingRunService
    # バックテストを enqueue する
    #
    # 重要 2 対応(02_§0.4 / §4.4.1): transaction ブロック内で perform_later を
    # 呼ぶアンチパターンを廃止し,Backtesting::Run.create! の AR 暗黙
    # transaction commit 後に perform_later が enqueue されるよう構成する.
    # ActiveJob 側の enqueue_after_transaction_commit = :always
    # (config/initializers/active_job.rb で Step 2-6.5 に追加予定)が
    # commit 後 enqueue を保証するため明示的な transaction は不要.
    #
    # @param definition_id [Integer]
    # @param strategy_revision_id [Integer]
    # @param risk_policy_id [Integer]
    # @param symbol [String]
    # @param granularity [String]
    # @param period_from [Time]
    # @param period_to [Time]
    # @param fee_rate [BigDecimal]
    # @param slippage_rate [BigDecimal]
    # @param include_funding_rate [Boolean]
    # @param use_mark_basis [Boolean]
    # @param use_spot_basis [Boolean]
    # @return [Backtesting::Run] status: pending の Run
    # @raise [ActiveRecord::RecordNotFound] strategy_revision_id の Revision が不在
    # @raise [ArgumentError] 整合検証違反 / 受入条件違反
    def enqueue_backtest(definition_id:, strategy_revision_id:, risk_policy_id:,
                         symbol:, granularity:, period_from:, period_to:,
                         fee_rate:, slippage_rate:,
                         include_funding_rate: false,
                         use_mark_basis: false,
                         use_spot_basis: false)
      revision = Strategy::Revision.assert_strategy_definition_consistency!(strategy_revision_id, definition_id)
      raise ArgumentError, "revision must be acceptable for backtest" unless revision.acceptable_for_backtest?

      run = Backtesting::Run.create!(
        strategy_definition_id: definition_id,
        strategy_revision_id: revision.id,
        risk_policy_id: risk_policy_id,
        symbol: symbol,
        granularity: granularity,
        period_from: period_from,
        period_to: period_to,
        fee_rate: fee_rate,
        slippage_rate: slippage_rate,
        include_funding_rate: include_funding_rate,
        use_mark_basis: use_mark_basis,
        use_spot_basis: use_spot_basis,
        status: "pending"
      )
      BacktestExecutionJob.perform_later(run.id)
      run
    end

    # Run をキャンセルする
    #
    # @param run_id [Integer]
    # @return [Backtesting::Run] terminal 状態なら変化なし、それ以外は cancelled へ遷移
    # @raise [ActiveRecord::RecordNotFound]
    def cancel(run_id:)
      run = Backtesting::Run.find(run_id)
      return run if run.terminal?

      run.cancel!
      run
    end

    # Run を取得する(metrics を eager load)
    #
    # @param run_id [Integer]
    # @return [Backtesting::Run]
    # @raise [ActiveRecord::RecordNotFound]
    def get(run_id:)
      Backtesting::Run.includes(:metrics).find(run_id)
    end

    # Run の一覧を created_at 降順で返す(filters でフィルタ可能)
    #
    # @param filters [Hash] :strategy_definition_id / :status を受け付ける
    # @return [ActiveRecord::Relation<Backtesting::Run>]
    def list(filters: {})
      scope = Backtesting::Run.order(created_at: :desc)
      scope = scope.where(strategy_definition_id: filters[:strategy_definition_id]) if filters[:strategy_definition_id]
      scope = scope.where(status: filters[:status]) if filters[:status]
      scope
    end
  end
end
