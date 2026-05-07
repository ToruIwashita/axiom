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
#   5. server_time(clock sync)         ← 3.3-9b 実装済
#   6. contract_metadata(symbol)        ← 3.3-9b 実装済
#   7. set_margin_mode + set_position_mode + set_asset_mode + set_leverage  ← 3.3-9b 実装済
#   8. history_candles(warmup_range)    ← 3.3-9b 実装済
#   9. Public WS connect + subscribe    ← 3.3-9c 実装済
#  10. Private WS connect + login + subscribe ← 3.3-9c 実装済
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
  # @param clock_sync [Infrastructure::BitgetClockSync, nil] step 5 で server_time 同期に利用
  # @param market_endpoint [Infrastructure::BitgetMarketEndpoint, nil] step 6 (contract_metadata) / step 8 (history_candles)
  # @param position_endpoint [Infrastructure::BitgetPositionEndpoint, nil] step 7 (margin/position/asset/leverage settings)
  # @param public_ws_factory [Proc, nil] Public WS Client 生成 Proc(step 9 で `.call` 遅延生成)
  # @param private_ws_factory [Proc, nil] Private WS Client 生成 Proc(step 10 で `.call` 遅延生成)
  # @param logger [Logger] release! 例外等の警告出力先
  def initialize(
    process_manager: Domain::LiveTradingProcessManager.new,
    clock_sync: nil,
    market_endpoint: nil,
    position_endpoint: nil,
    public_ws_factory: nil,
    private_ws_factory: nil,
    logger: Rails.logger
  )
    @process_manager = process_manager
    @clock_sync = clock_sync
    @market_endpoint = market_endpoint
    @position_endpoint = position_endpoint
    @public_ws_factory = public_ws_factory
    @private_ws_factory = private_ws_factory
    @logger = logger
  end

  # Worker のエントリポイント.
  #
  # @param session_id [Integer] LiveTrading::Session の ID
  # @return [void]
  # @raise [ActiveRecord::RecordNotFound] step 1/3 で対象が見つからない場合
  # @raise [ArgumentError] step 2 整合 / 受入条件不合格の場合
  # @raise [LiveTrading::SessionLease::ActiveLeaseError] step 4 で既に active な lease がある場合
  def perform(session_id)
    @worker_instance_id = jid.presence || "manual-#{Socket.gethostname}-#{Process.pid}-#{SecureRandom.hex(4)}"
    bootstrap_session(session_id)
  end

  # warmup MVP デフォルト(設計書 05_§3.3 step 8 / 3.3-9b 引き継ぎ事項として
  # strategy ごとの granularity / warmup_period 切替は将来 phase で対応予定)
  WARMUP_GRANULARITY = "1m".freeze
  WARMUP_LIMIT = 200

  private_constant :WARMUP_GRANULARITY, :WARMUP_LIMIT

  private

  attr_reader :process_manager, :logger

  def bootstrap_session(session_id)
    session = nil
    lease = nil
    public_ws = nil
    private_ws = nil

    begin
      session = LiveTrading::Session.find(session_id)
      load_revision_with_consistency(session)
      Risk::Policy.find(session.risk_policy_id)
      lease = process_manager.acquire_lease!(session: session, worker_instance_id: @worker_instance_id)
      sync_clock_or_raise!
      fetch_contract_metadata(session)
      apply_account_settings(session)
      fetch_warmup_candles(session)
      public_ws = connect_public_ws(session)
      private_ws = connect_private_ws(session)
      # step 11-13 は 3.3-9d で実装予定
    rescue StandardError => e
      cleanup_on_failure(session: session, lease: lease, public_ws: public_ws, private_ws: private_ws, error: e)
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

  # step 5: server_time 同期. clock_sync.sync! は失敗時 nil を返すため raise に昇格させる.
  def sync_clock_or_raise!
    raise StandardError, "clock sync failed (server_time API)" if clock_sync.sync!.nil?
  end

  # step 6: contract_metadata 取得(tick_size 等). 戻り値は 3.3-10 メインループで使用予定.
  def fetch_contract_metadata(session)
    market_endpoint.contract_metadata(symbol: session.symbol)
  end

  # step 7: account settings(margin_mode / position_mode / asset_mode / leverage)を Bitget API で適用.
  def apply_account_settings(session)
    position_endpoint.set_margin_mode(
      symbol: session.symbol,
      margin_coin: session.margin_coin,
      margin_mode: session.margin_mode
    )
    position_endpoint.set_position_mode(position_mode: session.position_mode)
    position_endpoint.set_asset_mode(asset_mode: session.asset_mode)
    position_endpoint.set_leverage(
      symbol: session.symbol,
      margin_coin: session.margin_coin,
      leverage: session.leverage
    )
  end

  # step 8: warmup candles 取得. 戻り値は 3.3-10 メインループで indicator 初期化に使用予定.
  def fetch_warmup_candles(session)
    market_endpoint.history_futures_candles(
      symbol: session.symbol,
      granularity: WARMUP_GRANULARITY,
      limit: WARMUP_LIMIT
    )
  end

  # step 9: Public WS connect + subscribe(ticker / candle1m / books5).
  # WS instance は public_ws_factory.call で遅延生成(設計書 02_§5.2.6 / 3.3-9a peer review 重要 obs 2 反映).
  # callback は 3.3-10 メインループで実装(本 step では subscribe 経路を確立するのみ).
  def connect_public_ws(session)
    public_ws = public_ws_factory.call
    public_ws.connect
    public_subscriptions(session).each do |sub|
      public_ws.subscribe(sub) { |_msg| } # rubocop:disable Lint/EmptyBlock
    end
    public_ws
  end

  # step 10: Private WS connect(login + heartbeat 起動)+ subscribe(orders / orders-algo / fill / positions / positions-history / account).
  # `LoginFailedError` / `SubscribeFailedError` は connect 内で raise → bootstrap_session の rescue で
  # cleanup_on_failure 経由 disconnect + lease.release! が実行される(設計書レビュー軽微 2 反映).
  def connect_private_ws(session)
    private_ws = private_ws_factory.call
    private_subscriptions(session).each do |sub|
      private_ws.subscribe(sub) { |_msg| } # rubocop:disable Lint/EmptyBlock
    end
    private_ws.connect
    private_ws
  end

  def public_subscriptions(session)
    [
      Infrastructure::BitgetPublicWsSubscription.new(channel: "ticker", inst_type: "USDT-FUTURES", inst_id: session.symbol),
      Infrastructure::BitgetPublicWsSubscription.new(channel: "candle1m", inst_type: "USDT-FUTURES", inst_id: session.symbol),
      Infrastructure::BitgetPublicWsSubscription.new(channel: "books5", inst_type: "USDT-FUTURES", inst_id: session.symbol)
    ]
  end

  def private_subscriptions(session)
    %w[orders orders-algo fill positions positions-history account].map do |channel|
      Infrastructure::BitgetPrivateWsSubscription.new(channel: channel, inst_type: "USDT-FUTURES", inst_id: session.symbol)
    end
  end

  # 遅延初期化: spec では DI で mock を渡し, production では Rails.application.credentials から生成.
  def clock_sync
    @clock_sync ||= Infrastructure::BitgetClockSync.new(rest_client: build_rest_client, logger: logger)
  end

  def market_endpoint
    @market_endpoint ||= Infrastructure::BitgetMarketEndpoint.new(rest_client: build_rest_client)
  end

  def position_endpoint
    @position_endpoint ||= Infrastructure::BitgetPositionEndpoint.new(rest_client: build_rest_client)
  end

  # WS factory は Proc を保持し step 9/10 内で `.call` で遅延生成する
  # (Sidekiq Job Worker.new 時点での副作用 connect / 24h reconnect 時の既存 instance 再利用不可を防ぐ
  # / 3.3-9a peer review 重要 obs 2 反映).
  def public_ws_factory
    @public_ws_factory ||= lambda do
      Infrastructure::BitgetPublicWsClient.new(
        paptrading_enabled: bitget_paptrading_enabled?,
        logger: logger
      )
    end
  end

  def private_ws_factory
    @private_ws_factory ||= lambda do
      Infrastructure::BitgetPrivateWsClient.new(
        api_key: bitget_credentials.fetch(:api_key),
        passphrase: bitget_credentials.fetch(:passphrase),
        signer: Infrastructure::BitgetSigner.new(secret_key: bitget_credentials.fetch(:secret_key)),
        paptrading_enabled: bitget_paptrading_enabled?,
        logger: logger
      )
    end
  end

  def build_rest_client
    @rest_client ||= Infrastructure::BitgetRestClient.new(
      api_key: bitget_credentials.fetch(:api_key),
      secret_key: bitget_credentials.fetch(:secret_key),
      passphrase: bitget_credentials.fetch(:passphrase)
    )
  end

  def bitget_credentials
    @bitget_credentials ||= {
      api_key: Rails.application.credentials.dig(:bitget, :api_key),
      secret_key: Rails.application.credentials.dig(:bitget, :secret_key),
      passphrase: Rails.application.credentials.dig(:bitget, :passphrase)
    }
  end

  def bitget_paptrading_enabled?
    Rails.application.credentials.dig(:bitget, :paptrading_enabled) == true
  end

  # bootstrap 失敗時のクリーンアップ.責務分担は class doc コメント参照.
  #
  # 重要 obs 1(Phase 2 重要 5 race パターン踏襲): session.reload で DB 最新状態確認.
  # 別プロセス(管理画面 / kill-switch API)が status を更新している race window で
  # mark_failed_to_start! が halted/stopped 履歴を上書きするのを防ぐ.
  #
  # 軽微 obs 1(release! 例外連鎖失敗対策): lease.release! / WS.disconnect が raise しても
  # session 状態確定(failed_to_start 遷移)を保証する. 個別の例外は logger.warn に落とし.
  def cleanup_on_failure(session:, lease:, public_ws:, private_ws:, error:)
    return if session.nil?
    return if session.reload.terminal?

    safe_disconnect(private_ws, name: "private_ws")
    safe_disconnect(public_ws, name: "public_ws")

    if lease && !lease.state_released?
      begin
        lease.release!
      rescue StandardError => release_error
        logger.warn(
          "[LiveTradingWorker] lease.release! failed during cleanup_on_failure: " \
          "#{release_error.class.name}: #{release_error.message}"
        )
      end
    end

    session.mark_failed_to_start!(reason: "#{error.class.name}: #{error.message}")
  end

  # WS disconnect で例外発生時に他の cleanup を妨げないよう logger.warn に落とす.
  def safe_disconnect(ws, name:)
    return unless ws
    return unless ws.connected?

    ws.disconnect
  rescue StandardError => disconnect_error
    logger.warn(
      "[LiveTradingWorker] #{name}.disconnect failed during cleanup_on_failure: " \
      "#{disconnect_error.class.name}: #{disconnect_error.message}"
    )
  end
end
