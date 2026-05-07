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
#  11. reconciliation(start_reconciling 遷移 + REST 突合) ← 3.3-9d 実装済(REST 突合内部は 3.3-11 で対応)
#  12. SessionState load                ← 3.3-9d 実装済
#  13. mark_running(reconciling → running) ← 3.3-9d 実装済
#
# bootstrap 失敗時のクリーンアップ責務(設計書 02_§5.2.6 / レビュー軽微 1 + 軽微 2):
#   - step 1   失敗(Session 不在): cleanup 対象なし(raise のみ)
#   - step 2-3 失敗(Session 取得済み, lease 未取得): mark_failed_to_start! のみ
#   - step 4   失敗(lease acquire 失敗): mark_failed_to_start! のみ ← 軽微 1
#   - step 5+ 失敗: mark_failed_to_start! + lease.release!(以降 sub-commit で WS disconnect 追加)
class LiveTradingWorker
  include Sidekiq::Job
  sidekiq_options retry: false, queue: :live_trading

  # メインループ poll 間隔(設計書 02_§5.2.6).
  DEFAULT_MAIN_LOOP_POLL_INTERVAL = 1.0

  private_constant :DEFAULT_MAIN_LOOP_POLL_INTERVAL

  # @param process_manager [Domain::LiveTradingProcessManager]
  # @param clock_sync [Infrastructure::BitgetClockSync, nil] step 5 で server_time 同期に利用
  # @param market_endpoint [Infrastructure::BitgetMarketEndpoint, nil] step 6 (contract_metadata) / step 8 (history_candles)
  # @param position_endpoint [Infrastructure::BitgetPositionEndpoint, nil] step 7 (margin/position/asset/leverage settings)
  # @param public_ws_factory [Proc, nil] Public WS Client 生成 Proc(step 9 で `.call` 遅延生成)
  # @param private_ws_factory [Proc, nil] Private WS Client 生成 Proc(step 10 で `.call` 遅延生成)
  # @param runner_child_spawner [Infrastructure::StrategyRunnerChildSpawner, nil] live_runner_child 起動用
  # @param main_loop_poll_interval [Float] メインループ kill-switch / 状態 poll 間隔(秒). spec で 0 を渡して即時 break.
  # @param logger [Logger] release! 例外等の警告出力先
  def initialize(
    process_manager: Domain::LiveTradingProcessManager.new,
    clock_sync: nil,
    market_endpoint: nil,
    position_endpoint: nil,
    public_ws_factory: nil,
    private_ws_factory: nil,
    runner_child_spawner: nil,
    main_loop_poll_interval: DEFAULT_MAIN_LOOP_POLL_INTERVAL,
    logger: Rails.logger
  )
    @process_manager = process_manager
    @clock_sync = clock_sync
    @market_endpoint = market_endpoint
    @position_endpoint = position_endpoint
    @public_ws_factory = public_ws_factory
    @private_ws_factory = private_ws_factory
    @runner_child_spawner = runner_child_spawner
    @main_loop_poll_interval = main_loop_poll_interval
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
    @session = nil
    @lease = nil
    @public_ws = nil
    @private_ws = nil

    bootstrap_session(session_id)
    enter_main_loop
  end

  # warmup MVP デフォルト(設計書 05_§3.3 step 8 / 3.3-9b 引き継ぎ事項として
  # strategy ごとの granularity / warmup_period 切替は将来 phase で対応予定)
  WARMUP_GRANULARITY = "1m".freeze
  WARMUP_LIMIT = 200

  private_constant :WARMUP_GRANULARITY, :WARMUP_LIMIT

  private

  attr_reader :process_manager, :logger

  def bootstrap_session(session_id)
    @session = LiveTrading::Session.find(session_id)
    load_revision_with_consistency(@session)
    Risk::Policy.find(@session.risk_policy_id)
    @lease = process_manager.acquire_lease!(session: @session, worker_instance_id: @worker_instance_id)
    sync_clock_or_raise!
    fetch_contract_metadata(@session)
    apply_account_settings(@session)
    fetch_warmup_candles(@session)
    @public_ws = connect_public_ws(@session)
    @private_ws = connect_private_ws(@session)
    run_reconciliation(@session)
    load_session_state(@session)
    mark_running(@session)
  rescue StandardError => e
    cleanup_on_failure(session: @session, lease: @lease, public_ws: @public_ws, private_ws: @private_ws, error: e)
    raise
  end

  # bootstrap 完了後に呼ばれるメインループ.
  # 設計書 02_§5.2.6: WS push 受信は別 thread で callback 経由(3.3-10b/c で実装),
  # 本 main loop は kill-switch / session terminal / WS health を一定間隔でポーリングする.
  # heartbeat / lease renew は 3.3-12 で追加予定.
  #
  # 終了経路:
  #   - kill-switch 検出(session.status == :stopping): mark_stopped! へ遷移
  #   - session terminal(他プロセスが状態確定済み): 何もしない
  #   - WS 切断検知: mark_halted!(reason: ws_disconnected)
  def enter_main_loop
    exit_reason = nil
    loop do
      exit_reason = check_loop_exit_condition
      break if exit_reason

      sleep(@main_loop_poll_interval)
    end

    finalize_main_loop(exit_reason: exit_reason)
  end

  def check_loop_exit_condition
    return :terminal if @session.reload.terminal?
    return :kill_switch if process_manager.signal_kill_switch?(session: @session)
    return :ws_disconnected unless ws_healthy?

    nil
  end

  def ws_healthy?
    @public_ws && @public_ws.connected? && @private_ws && @private_ws.connected?
  end

  # main loop 終了時の状態遷移 + リソース解放.
  # session 状態遷移後 → WS disconnect → lease release の順で安全に解放する.
  def finalize_main_loop(exit_reason:)
    transition_session_for_exit(exit_reason)
    safe_disconnect(@private_ws, name: "private_ws", context: "finalize_main_loop")
    safe_disconnect(@public_ws, name: "public_ws", context: "finalize_main_loop")
    safe_release_lease(@lease, context: "finalize_main_loop")
  end

  def transition_session_for_exit(exit_reason)
    return unless @session

    @session.reload
    case exit_reason
    when :kill_switch
      # signal_kill_switch? は session.state_stopping? を意味するため stopping → stopped に遷移
      @session.mark_stopped! if @session.state_stopping?
    when :ws_disconnected
      reason = ws_disconnected_reason
      @session.mark_halted!(reason: reason) unless @session.terminal?
    when :terminal
      # 他プロセスが既に状態確定済み. 何もしない.
    end
  end

  # 3.3-10a peer review 軽微 obs 3 反映: 運用調査時に public_ws / private_ws どちらが切れたかを
  # session.failure_reason で追跡可能にする.
  def ws_disconnected_reason
    "ws_disconnected: public_ws=#{@public_ws&.connected?} private_ws=#{@private_ws&.connected?}"
  end

  # 3.3-10a peer review 軽微 obs 4 反映: cleanup_on_failure / finalize_main_loop の両方から
  # 共通呼出する DRY helper. context は logger.warn メッセージで呼出元を追跡可能にする.
  def safe_release_lease(lease, context:)
    return unless lease
    return if lease.state_released?

    lease.release!
  rescue StandardError => release_error
    logger.warn(
      "[LiveTradingWorker] lease.release! failed during #{context}: " \
      "#{release_error.class.name}: #{release_error.message}"
    )
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
  # subscribe callback は 3.3-10b でメインループ用 handler を実装した(handle_public_ws_message).
  def connect_public_ws(session)
    public_ws = public_ws_factory.call
    public_ws.connect
    public_subscriptions(session).each do |sub|
      public_ws.subscribe(sub) { |msg| handle_public_ws_message(sub, msg) }
    end
    public_ws
  end

  # Public WS callback handler(WebSocket Client thread から呼ばれる).
  # candle1m 以外の channel は 3.3-10 では未処理(MVP では candle1m のみ)で,後続 phase で対応.
  # callback 内例外は logger.warn に落として WS thread を止めない.
  def handle_public_ws_message(sub, msg)
    case sub.channel
    when "candle1m"
      handle_candle_message(msg)
    end
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] handle_public_ws_message failed in channel=#{sub.channel}: " \
      "#{e.class.name}: #{e.message}"
    )
  end

  # candle1m push を受信して確定 candle を検出する.
  # Bitget WS は同 ts の candle を複数回更新 push し, ts 進入で前 candle が確定する.
  # 確定検出時は spawn_runner_child_for_tick(candle)を別 thread で呼び出す.
  def handle_candle_message(msg)
    return unless msg.is_a?(Hash)

    rows = msg["data"]
    return unless rows.is_a?(Array)

    rows.each do |row|
      confirmed = detect_confirmed_candle(row)
      next unless confirmed

      spawn_runner_child_for_tick(confirmed)
    end
  end

  # 受信 row から確定 candle を判定する.
  # 直前に保持した row より ts が進んでいたら 直前 row が確定 candle として返る.
  # 初回受信(@last_candle_row が nil)の場合は確定なし.
  def detect_confirmed_candle(row)
    new_ts = row[0].to_i
    prev_row = @last_candle_row
    @last_candle_row = row

    return nil if prev_row.nil?

    prev_ts = prev_row[0].to_i
    return nil if prev_ts == new_ts

    build_candle_payload(prev_row)
  end

  def build_candle_payload(row)
    {
      "ts" => row[0].to_i,
      "open" => row[1],
      "high" => row[2],
      "low" => row[3],
      "close" => row[4],
      "base_volume" => row[5],
      "quote_volume" => row[6]
    }
  end

  # 確定 candle を子プロセスで処理するため別 thread + AR pool を確保して実行する
  # (3.3-10a peer review 重要 obs 1 反映 / WS callback thread-safety guideline (a)(c)).
  # spec では run_in_db_thread を stub して同期化し検証する.
  def spawn_runner_child_for_tick(candle)
    run_in_db_thread("runner_child_for_tick") do
      reloaded_session = LiveTrading::Session.find(@session.id) # guideline (b)
      run_runner_child_for_tick(reloaded_session, candle)
    end
  end

  # WS callback thread から DB アクセスを伴う処理を別 thread で実行する共通 helper.
  # production: 別 thread + ActiveRecord::Base.connection_pool.with_connection で connection 確保.
  # spec: 同期化のため allow(worker).to receive(:run_in_db_thread) { |label, &block| block.call } で差替.
  def run_in_db_thread(label)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { yield }
    rescue StandardError => e
      logger.error(
        "[LiveTradingWorker] background task '#{label}' failed: " \
        "#{e.class.name}: #{e.message}"
      )
    end
  end

  # candle 確定 → live_runner_child 起動 → on_tick callback の中身(3.3-10d で完成).
  # 本 step(3.3-10b)では skeleton method として登録するに留め, 内部実装は 3.3-10d で:
  # - ctx_input 構築(candle / state / balance 等)
  # - runner_child_spawner.run(callback: :on_tick, revision:, ctx_input:)
  # - 戻り値 order_intents → AI filter → RiskGuard → 発注
  def run_runner_child_for_tick(_session, _candle)
    # 3.3-10d で実装予定
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

  # step 11: reconciliation(6 件 REST 突合 / starting → reconciling 遷移 + REST 突合).
  # 6 件の REST 突合(orders-pending / orders-plan-pending / orders-plan-history /
  # plan-sub-order / position-all / fill-history)の内部実装は 3.3-11 で対応予定.
  # 本 step では `start_reconciling!` 遷移と method skeleton のみを確立する.
  def run_reconciliation(session)
    session.start_reconciling!
    # TODO(3.3-11): 6 件 REST 突合実装(orders-pending, orders-plan-pending, orders-plan-history,
    #               plan-sub-order, position-all, fill-history)
  end

  # step 12: SessionState 復元(初回起動時は空 state_data で create, 再起動時は既存をロード).
  def load_session_state(session)
    LiveTrading::SessionState.find_or_create_by!(live_trading_session_id: session.id) do |s|
      s.state_data = {}
    end
  end

  # step 13: reconciling → running 遷移(started_at = Time.current 自動設定).
  def mark_running(session)
    session.start_running!
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

  def runner_child_spawner
    @runner_child_spawner ||= Infrastructure::StrategyRunnerChildSpawner.new(
      runner_script_path: Rails.root.join("lib/live_runner_child.rb").to_s
    )
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

    safe_disconnect(private_ws, name: "private_ws", context: "cleanup_on_failure")
    safe_disconnect(public_ws, name: "public_ws", context: "cleanup_on_failure")
    safe_release_lease(lease, context: "cleanup_on_failure")

    session.mark_failed_to_start!(reason: "#{error.class.name}: #{error.message}")
  end

  # WS disconnect で例外発生時に他の cleanup を妨げないよう logger.warn に落とす.
  # context は呼出元(cleanup_on_failure / finalize_main_loop)を logger メッセージで追跡可能にする.
  def safe_disconnect(ws, name:, context:)
    return unless ws
    return unless ws.connected?

    ws.disconnect
  rescue StandardError => disconnect_error
    logger.warn(
      "[LiveTradingWorker] #{name}.disconnect failed during #{context}: " \
      "#{disconnect_error.class.name}: #{disconnect_error.message}"
    )
  end
end
