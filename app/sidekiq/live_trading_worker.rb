# ライブトレード実行 Worker(Sidekiq Job).
#
# Sidekiq の入口に徹し,ロジックは `Domain::LiveTradingProcessManager` 等の Domain サービスへ委譲する
# (設計書 02_§5.2.6 / 03_§9.3 / 05_§3.3 + 4.4.2).
#
# bootstrap 13 ステップ(設計書 05_§3.3 / 01_§2.2):
#   1. Session.find
#   2. Revision.find + 整合検証 + 受入条件チェック
#   3. Risk::Policy.find
#   4. SessionLease.acquire!(TTL 5 分)
#   5. server_time(clock sync)         ← 3.3-9b で実装予定
#   6. contract_metadata(symbol)        ← 3.3-9b で実装予定
#   7. set_margin_mode + set_position_mode + set_asset_mode + set_leverage  ← 3.3-9b
#   8. history_candles(warmup_range)    ← 3.3-9b で実装予定
#   9. Public WS connect + subscribe    ← 3.3-9c で実装予定
#  10. Private WS connect + login + subscribe ← 3.3-9c で実装予定
#  11. reconciliation(6 件 REST 突合)  ← 3.3-9d / 3.3-11
#  12. SessionState load                ← 3.3-9d で実装予定
#  13. mark_running                     ← 3.3-9d で実装予定
#
# bootstrap 失敗時のクリーンアップ責務(設計書 02_§5.2.6 / レビュー軽微 1 + 軽微 2):
#   - step 1   失敗(Session 不在): cleanup 対象なし(raise のみ)
#   - step 2-3 失敗(Session 取得済み, lease 未取得): mark_failed_to_start! のみ
#   - step 4   失敗(lease acquire 失敗): mark_failed_to_start! のみ ← 軽微 1
#   - step 5+ 失敗: mark_failed_to_start! + lease.release!(以降 sub-commit で WS disconnect 追加)
class LiveTradingWorker
  include Sidekiq::Job
  sidekiq_options retry: false, queue: :live_trading

  # @param process_manager [Domain::LiveTradingProcessManager]
  def initialize(process_manager: Domain::LiveTradingProcessManager.new)
    @process_manager = process_manager
  end

  # Worker のエントリポイント.
  #
  # @param session_id [Integer] LiveTrading::Session の ID
  # @return [void]
  # @raise [ActiveRecord::RecordNotFound] step 1/3 で対象が見つからない場合
  # @raise [ArgumentError] step 2 整合 / 受入条件不合格の場合
  # @raise [LiveTrading::SessionLease::ActiveLeaseError] step 4 で既に active な lease がある場合
  def perform(session_id)
    @worker_instance_id = (jid if respond_to?(:jid)) ||
                          "manual-#{Socket.gethostname}-#{Process.pid}-#{SecureRandom.hex(4)}"
    bootstrap_session(session_id)
  end

  private

  attr_reader :process_manager

  def bootstrap_session(session_id)
    session = nil
    lease = nil

    begin
      session = LiveTrading::Session.find(session_id)
      load_revision_with_consistency(session)
      Risk::Policy.find(session.risk_policy_id)
      lease = process_manager.acquire_lease!(session: session, worker_instance_id: @worker_instance_id)
      # step 5-13 は 3.3-9b/c/d で実装予定
    rescue StandardError => e
      cleanup_on_failure(session: session, lease: lease, error: e)
      raise
    end
  end

  def load_revision_with_consistency(session)
    revision = Strategy::Revision.assert_strategy_definition_consistency!(
      session.strategy_revision_id, session.strategy_definition_id
    )

    unless revision.acceptable_for_live?
      raise ArgumentError,
            "revision id=#{revision.id} is not acceptable for live (status=#{revision.status})"
    end

    if revision.uses_live_forbidden_input
      raise ArgumentError, "revision id=#{revision.id} uses_live_forbidden_input is true"
    end

    revision
  end

  # bootstrap 失敗時のクリーンアップ.責務分担は class doc コメント参照.
  def cleanup_on_failure(session:, lease:, error:)
    return if session.nil?
    return if session.terminal?

    lease.release! if lease && !lease.state_released?
    session.mark_failed_to_start!(reason: "#{error.class.name}: #{error.message}")
  end
end
