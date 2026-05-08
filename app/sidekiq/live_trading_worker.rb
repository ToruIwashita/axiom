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
  # heartbeat 周期(設計書 02_§5.2.6 / 05_§7.2: 60 秒推奨).
  HEARTBEAT_INTERVAL_SECONDS = 60
  # lease renew 周期(設計書 02_§5.2.6 / 05_§7.2: 2 分推奨 / TTL 5 分の余裕を持たせた更新).
  LEASE_RENEW_INTERVAL_SECONDS = 120

  private_constant :DEFAULT_MAIN_LOOP_POLL_INTERVAL, :HEARTBEAT_INTERVAL_SECONDS, :LEASE_RENEW_INTERVAL_SECONDS

  # @param process_manager [Domain::LiveTradingProcessManager]
  # @param clock_sync [Infrastructure::BitgetClockSync, nil] step 5 で server_time 同期に利用
  # @param market_endpoint [Infrastructure::BitgetMarketEndpoint, nil] step 6 (contract_metadata) / step 8 (history_candles)
  # @param position_endpoint [Infrastructure::BitgetPositionEndpoint, nil] step 7 (margin/position/asset/leverage settings)
  # @param public_ws_factory [Proc, nil] Public WS Client 生成 Proc(step 9 で `.call` 遅延生成)
  # @param private_ws_factory [Proc, nil] Private WS Client 生成 Proc(step 10 で `.call` 遅延生成)
  # @param runner_child_spawner [Infrastructure::StrategyRunnerChildSpawner, nil] live_runner_child 起動用
  # @param ai_filter_service [Domain::AiFilterService, nil] order_intent 評価用 AI フィルタ
  # @param risk_guard_service [Domain::RiskGuardService, nil] entry / cooldown / halt 判定
  # @param order_endpoint [Infrastructure::BitgetOrderEndpoint, nil] 発注
  # @param main_loop_poll_interval [Float] メインループ kill-switch / 状態 poll 間隔(秒). spec で 0 を渡して即時 break.
  # @param monotonic_clock [#call] heartbeat / lease renew の周期判定用 monotonic clock(R-2 #5 反映).
  #   デフォルトは `Process.clock_gettime(Process::CLOCK_MONOTONIC)`. 壁時計逆行(NTP step / 手動修正)による
  #   heartbeat 停止 → SessionLease 奪取事故を防ぐ.
  # @param logger [Logger] release! 例外等の警告出力先
  def initialize(
    process_manager: Domain::LiveTradingProcessManager.new,
    clock_sync: nil,
    market_endpoint: nil,
    position_endpoint: nil,
    public_ws_factory: nil,
    private_ws_factory: nil,
    runner_child_spawner: nil,
    ai_filter_service: nil,
    risk_guard_service: nil,
    order_endpoint: nil,
    main_loop_poll_interval: DEFAULT_MAIN_LOOP_POLL_INTERVAL,
    monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
    logger: Rails.logger
  )
    @process_manager = process_manager
    @clock_sync = clock_sync
    @market_endpoint = market_endpoint
    @position_endpoint = position_endpoint
    @public_ws_factory = public_ws_factory
    @private_ws_factory = private_ws_factory
    @runner_child_spawner = runner_child_spawner
    @ai_filter_service = ai_filter_service
    @risk_guard_service = risk_guard_service
    @order_endpoint = order_endpoint
    @main_loop_poll_interval = main_loop_poll_interval
    @monotonic_clock = monotonic_clock
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
    @last_heartbeat_at = nil
    @last_lease_renew_at = nil
    @last_public_ws_reconnect_count = ws_reconnect_count(@public_ws)
    @last_private_ws_reconnect_count = ws_reconnect_count(@private_ws)

    loop do
      exit_reason = check_loop_exit_condition
      break if exit_reason

      pulse_heartbeat_if_due
      renew_lease_if_due
      detect_ws_reconnect_and_reconcile
      sleep(@main_loop_poll_interval)
    end

    finalize_main_loop(exit_reason: exit_reason)
  end

  # WS Client の reconnect_count から増分を検知し, 増えていれば reconciliation を再実行する
  # (Phase 1.3 引き継ぎ #13: 24h 切断後 reconciliation / 設計書 02_§5.2.6).
  # 別 thread + AR pool で実行(WS callback thread は触らないため main loop thread から起動).
  def detect_ws_reconnect_and_reconcile
    return unless @session

    public_count = ws_reconnect_count(@public_ws)
    private_count = ws_reconnect_count(@private_ws)
    public_reconnected = public_count > @last_public_ws_reconnect_count
    private_reconnected = private_count > @last_private_ws_reconnect_count

    @last_public_ws_reconnect_count = public_count
    @last_private_ws_reconnect_count = private_count

    return unless public_reconnected || private_reconnected

    logger.info(
      "[LiveTradingWorker] WS reconnect detected (public=#{public_reconnected}, " \
      "private=#{private_reconnected}), re-running reconciliation"
    )

    # R-2 #6 反映: WS reconnect 後は新旧受信 thread の race window が論理上発生し得るため,
    # @last_candle_row を nil リセットして次の確定判定を新 thread の最初の row から再開する
    # (snapshot 受信時と同様の振る舞い).
    @last_candle_row = nil if public_reconnected

    run_in_db_thread("reconcile_after_ws_reconnect") do
      session_reloaded = LiveTrading::Session.find(@session.id)
      run_reconciliation_after_reconnect(session_reloaded)
    end
  end

  # reconnect 後の reconciliation 再実行.
  # bootstrap step 11 と異なり session 状態遷移(start_reconciling!)は行わない
  # (running 状態のまま 6 件 REST 突合のみ実施).
  def run_reconciliation_after_reconnect(session)
    reconcile_orders_pending(session)
    reconcile_orders_plan_pending(session)
    reconcile_orders_plan_history(session)
    reconcile_position_all(session)
  end

  # WS Client の reconnect_count を安全に取得する(nil 防御 + respond_to? 防御).
  def ws_reconnect_count(ws)
    return 0 unless ws&.respond_to?(:reconnect_count)

    ws.reconnect_count.to_i
  end

  # heartbeat 周期到達時に process_manager.pulse_heartbeat! を呼ぶ.
  # 初回は @last_heartbeat_at が nil のため即時実行.
  # 失敗時は logger.warn 落とし(main loop を止めない).
  # 周期判定は monotonic clock を使用し壁時計逆行による heartbeat 停止事故を防ぐ(R-2 #5 反映).
  def pulse_heartbeat_if_due
    now = @monotonic_clock.call
    return if @last_heartbeat_at && (now - @last_heartbeat_at) < HEARTBEAT_INTERVAL_SECONDS

    process_manager.pulse_heartbeat!(session: @session, worker_instance_id: @worker_instance_id)
    @last_heartbeat_at = now
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] pulse_heartbeat! failed: #{e.class.name}: #{e.message}"
    )
  end

  # lease renew 周期到達時に process_manager.renew_lease! を呼ぶ.
  # 初回は @last_lease_renew_at が nil のため即時実行.
  # 失敗時は logger.warn 落とし.
  # 周期判定は monotonic clock を使用(R-2 #5 反映).
  def renew_lease_if_due
    now = @monotonic_clock.call
    return if @last_lease_renew_at && (now - @last_lease_renew_at) < LEASE_RENEW_INTERVAL_SECONDS
    return unless @lease

    process_manager.renew_lease!(lease: @lease)
    @last_lease_renew_at = now
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] renew_lease! failed: #{e.class.name}: #{e.message}"
    )
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
  # subscribe callback は (data, result) の 2 引数で BitgetPublicWsClient から呼ばれる.
  def connect_public_ws(session)
    public_ws = public_ws_factory.call
    public_ws.connect
    public_subscriptions(session).each do |sub|
      public_ws.subscribe(sub) { |data, result| handle_public_ws_message(sub, data, result) }
    end
    public_ws
  end

  # Public WS callback handler(WebSocket Client thread から呼ばれる).
  # candle1m 以外の channel は 3.3-10 では未処理(MVP では candle1m のみ)で,後続 phase で対応.
  # callback 内例外は logger.warn に落として WS thread を止めない.
  #
  # @param sub [Infrastructure::BitgetPublicWsSubscription] subscription オブジェクト
  # @param data [Array, nil] WS push の data 部分(BitgetPublicWsMessageDecoder Push.data)
  # @param result [Infrastructure::BitgetPublicWsMessageDecoder::Result::Push] snapshot? / update? 判定用
  def handle_public_ws_message(sub, data, result)
    case sub.channel
    when "candle1m"
      handle_candle_message(data, snapshot: result.respond_to?(:snapshot?) && result.snapshot?)
    end
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] handle_public_ws_message failed in channel=#{sub.channel}: " \
      "#{e.class.name}: #{e.message}"
    )
  end

  # candle1m push を受信して確定 candle を検出する.
  # Bitget WS は接続直後に snapshot(過去履歴 N 本)を 1 push で送り, その後は update(同 ts 更新)+
  # ts 進入で前 candle 確定の流れになる.
  # snapshot 時は最新 row(末尾)で @last_candle_row を初期化するのみ(spawn しない /
  # warmup_candles は別途 step 8 で REST 取得済 + snapshot 内 row 全件 spawn は二重発注事故になるため).
  # update 時は data の各 row を順次確定判定する.
  # multiple-agent review R-1 #2 反映.
  #
  # @param data [Array<Array>, nil] WS push data 部分(各要素は OHLCV row)
  # @param snapshot [Boolean] result.snapshot? 由来 / true なら確定判定スキップ
  def handle_candle_message(data, snapshot: false)
    return unless data.is_a?(Array) && data.any?

    if snapshot
      @last_candle_row = data.last
      return
    end

    data.each do |row|
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

  # candle 確定 → live_runner_child 起動 → on_tick callback → order_intents 評価 → 発注 (3.3-10d).
  # 1. ctx_input 構築(candle / state / symbol)
  # 2. runner_child_spawner.run(callback: :on_tick, revision:, ctx_input:)
  # 3. 戻り値 strategy_state_diff → SessionState.apply_diff! で state 同期
  # 4. order_intents 評価ループ → AI filter → RiskGuard → place_order
  def run_runner_child_for_tick(session, candle)
    revision = session.strategy_revision
    state = session.session_state || LiveTrading::SessionState.create!(live_trading_session_id: session.id, state_data: {})

    response = runner_child_spawner.run(
      callback: :on_tick,
      revision: revision,
      ctx_input: build_runner_ctx_input(session, candle, state)
    )

    unless response["status"] == "ok"
      logger.warn(
        "[LiveTradingWorker] live_runner_child returned non-ok status=#{response['status']}: " \
        "errors=#{response['errors'].inspect}"
      )
      return
    end

    apply_strategy_state_diff(state, response["strategy_state_diff"])

    Array(response["order_intents"]).each_with_index do |intent, idx|
      process_order_intent(session, revision, intent, candle, idx)
    end
  end

  # Domain::LiveContext.build_ctx_input に委譲して子プロセスへ渡す形式を構築する.
  # MVP では position / balance を placeholder(no-position / 残高 0)で送信する
  # (multiple-agent review R-1 #1 反映: LiveContext.from_ctx_input の必須キー満たす契約整合).
  # TODO(後続 phase): account_endpoint で実 balance + position を取得して付与
  def build_runner_ctx_input(_session, candle, state)
    Domain::LiveContext.build_ctx_input(
      candle: candle,
      position: Domain::PositionValueObject.new,
      balance: BigDecimal("0"),
      state: state.state_data
    )
  end

  # strategy_state_diff の各 op を SessionState.apply_diff! で適用.
  # MVP は replace_all のみ対応(SessionState 内部で fail-fast 検証).
  # thread-safety guideline (d): transaction 隔離.
  def apply_strategy_state_diff(state, diff)
    return if diff.nil?

    ops = Array(diff["ops"])
    return if ops.empty?

    LiveTrading::Session.transaction do
      ops.each { |op| state.apply_diff!(diff: op) }
    end
  end

  # 1 件の order_intent を AI filter → RiskGuard → 発注の順に評価する.
  # いずれかで否決された場合は place_order を呼ばない.
  # 単一 intent 内例外は logger.warn に落として他 intent の処理を妨げない.
  # candle / idx は client_oid 決定論的生成(R-1 #3 反映)に利用.
  def process_order_intent(session, revision, intent, candle, idx)
    return unless ai_filter_pass?(revision, intent)
    return unless risk_guard_pass?(session, intent)

    place_order_for_intent(session, intent, candle, idx)
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] process_order_intent failed (intent=#{intent.inspect}): " \
      "#{e.class.name}: #{e.message}"
    )
  end

  # AI filter 通過判定. ai_filter_enabled=false なら常に通過.
  # ai_filter_enabled=true で nil 戻り(validation_failed)は否決(エントリー見送り固定 / 設計書整合).
  def ai_filter_pass?(revision, intent)
    return true unless revision.ai_filter_enabled

    result = ai_filter_service.call(
      template: revision.ai_filter_template_name,
      context: intent,
      context_type: "entry_filter",
      timeout_sec: revision.ai_filter_timeout_sec || 5.0,
      fail_safe: revision.ai_filter_fail_safe || "skip"
    )
    return false if result.nil?

    result["enter"] == true
  end

  # RiskGuard 通過判定(allow_entry?). balance は 3.3-10d 範囲では 0 placeholder
  # (account_endpoint 経由の実 balance 取得は後続 phase で対応).
  def risk_guard_pass?(session, intent)
    candidate_size = BigDecimal(intent["size"].to_s)
    risk_guard_service.allow_entry?(
      session: session,
      balance: BigDecimal("0"), # TODO(後続 phase): account_endpoint で実 balance 取得
      candidate_size: candidate_size
    )
  end

  # order_intent → BitgetOrderEndpoint#place_order マッピング.
  # client_oid は intent 由来優先 / 未指定なら決定論的 ID 生成
  # (R-1 #3 反映: SecureRandom.uuid フォールバックは Worker 再起動 / WS reconnect 後の同 candle 再処理時に
  # 毎回別 uuid となり Bitget の冪等チェック通過 → 二重発注事故になるため決定論的生成に変更).
  def place_order_for_intent(session, intent, candle, idx)
    order_endpoint.place_order(
      symbol: session.symbol,
      margin_mode: session.margin_mode,
      margin_coin: session.margin_coin,
      side: intent["side"],
      order_type: intent["order_type"],
      size: intent["size"].to_s,
      force: intent.fetch("force", "gtc"),
      reduce_only: intent.fetch("reduce_only", "NO"),
      client_oid: intent["client_oid"] || deterministic_client_oid(session, candle, idx),
      trade_side: intent["trade_side"],
      price: intent["price"]&.to_s,
      preset_stop_surplus_price: intent["tp"]&.to_s,
      preset_stop_loss_price: intent["sl"]&.to_s
    )
  end

  # 同一 candle / 同一 intent index に対しては再起動後も同じ client_oid を返す決定論生成.
  # session.id + candle ts + intent index で一意.Bitget の冪等チェックで二重発注を防止する.
  def deterministic_client_oid(session, candle, idx)
    candle_ts = candle.is_a?(Hash) ? candle["ts"] : nil
    "live-#{session.id}-#{candle_ts}-#{idx}"
  end

  # Private WS callback handler(3.3-10c).
  # WebSocket Client thread から `(data, result)` で呼ばれる.
  # result は BitgetPrivateWsMessageDecoder::Result::Push で channel 述語 + algo state 述語を保持.
  # callback 内例外は logger.warn に落として WS thread を止めない.
  #
  # @param sub [Infrastructure::BitgetPrivateWsSubscription]
  # @param data [Array, nil] WS push の data 部分
  # @param result [Infrastructure::BitgetPrivateWsMessageDecoder::Result::Push]
  def handle_private_ws_message(sub, data, result)
    case sub.channel
    when "orders"            then handle_orders_message(data)
    when "orders-algo"       then handle_orders_algo_message(data, result)
    when "fill"              then handle_fill_message(data)
    when "positions"         then handle_positions_message(data)
    when "positions-history" then handle_positions_history_message(data)
    when "account"           then handle_account_message(data)
    end
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] handle_private_ws_message failed in channel=#{sub.channel}: " \
      "#{e.class.name}: #{e.message}"
    )
  end

  # orders push: Exchange::Order の状態更新(MVP では skeleton, 後続 phase で詳細実装).
  # thread-safety guideline (a)(c)(d): run_in_db_thread + with_connection + transaction 隔離.
  def handle_orders_message(data)
    run_in_db_thread("orders_update") do
      LiveTrading::Session.transaction do
        Array(data).each do |_row|
          # TODO(後続 phase): Exchange::Order upsert(client_oid / state / filled_size / avg_price 等)
        end
      end
    end
  end

  # orders-algo push: Exchange::AlgoOrder の状態更新 + algo_anomaly? なら reconciliation 起動.
  # result.algo_anomaly? の場合 設計書 05_§3.6 でアラート + reconciliation 起動と規定.
  def handle_orders_algo_message(data, result)
    if result.respond_to?(:algo_anomaly?) && result.algo_anomaly?
      logger.warn(
        "[LiveTradingWorker] orders-algo anomaly detected (state outside known set): " \
        "data=#{data.inspect}"
      )
      # TODO(後続 phase): reconciliation 起動 trigger
    end

    run_in_db_thread("orders_algo_update") do
      LiveTrading::Session.transaction do
        Array(data).each do |_row|
          # TODO(後続 phase): Exchange::AlgoOrder upsert(plan_id / state / trigger_price / callback_ratio 等)
        end
      end
    end
  end

  # fill push: Exchange::Fill の新規記録 + 関連 Trade 集計反映.
  def handle_fill_message(data)
    run_in_db_thread("fill_create") do
      LiveTrading::Session.transaction do
        Array(data).each do |_row|
          # TODO(後続 phase): Exchange::Fill create + LiveTrading::Trade 集計更新
        end
      end
    end
  end

  # positions push: Exchange::PositionSnapshot を最新値で upsert(snapshot 系 channel).
  def handle_positions_message(data)
    run_in_db_thread("positions_update") do
      LiveTrading::Session.transaction do
        Array(data).each do |_row|
          # TODO(後続 phase): Exchange::PositionSnapshot upsert(symbol / hold_side / size / margin / pnl 等)
        end
      end
    end
  end

  # positions-history push: 履歴系の PositionSnapshot 記録(close 時等).
  def handle_positions_history_message(data)
    run_in_db_thread("positions_history") do
      LiveTrading::Session.transaction do
        Array(data).each do |_row|
          # TODO(後続 phase): Exchange::PositionSnapshot 履歴 record + Trade 集計反映
        end
      end
    end
  end

  # account push: account 残高(margin balance / available 等)更新.
  # MVP では BalanceSnapshot モデルがないため skeleton(後続 phase で対応モデル追加 + 反映).
  def handle_account_message(data)
    run_in_db_thread("account_update") do
      Array(data).each do |_row|
        # TODO(後続 phase): account balance snapshot model 追加後に反映
      end
    end
  end

  # step 10: Private WS connect(login + heartbeat 起動)+ subscribe(orders / orders-algo / fill / positions / positions-history / account).
  # `LoginFailedError` / `SubscribeFailedError` は connect 内で raise → bootstrap_session の rescue で
  # cleanup_on_failure 経由 disconnect + lease.release! が実行される(設計書レビュー軽微 2 反映).
  # subscribe callback は (data, result) の 2 引数で呼ばれる(3.3-10c handler 経由).
  def connect_private_ws(session)
    private_ws = private_ws_factory.call
    private_subscriptions(session).each do |sub|
      private_ws.subscribe(sub) { |data, result| handle_private_ws_message(sub, data, result) }
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

  # step 11: reconciliation(starting → reconciling 遷移 + 6 件 REST 突合).
  # 各 REST 呼出は失敗時に logger.warn に落として後続 reconcile を継続する(部分復旧志向).
  # 各結果からの DB upsert は後続 phase で実装(現状は呼出構造のみ確立).
  #
  # MVP 範囲(5 件):
  # - orders_pending: 未約定通常注文
  # - orders_plan_pending: 未起動 plan order
  # - orders_plan_history: 履歴 plan order(直近 24h)
  # - position_all: 全 position
  # - plan_sub_order: orders_plan_pending 取得後に各 plan_id について(現状 skeleton)
  # 範囲外(将来 phase):
  # - fill_history: BitgetOrderEndpoint に対応 endpoint 未実装のため将来追加候補
  def run_reconciliation(session)
    session.start_reconciling!

    reconcile_orders_pending(session)
    reconcile_orders_plan_pending(session)
    reconcile_orders_plan_history(session)
    reconcile_position_all(session)
    # TODO(将来 phase): reconcile_fill_history(BitgetOrderEndpoint#fill_history 追加後)
  end

  def reconcile_orders_pending(session)
    response = order_endpoint.orders_pending(symbol: session.symbol)
    # TODO(後続 phase): response["data"] から Exchange::Order upsert
    response
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] reconcile_orders_pending failed: #{e.class.name}: #{e.message}"
    )
    nil
  end

  def reconcile_orders_plan_pending(session)
    response = order_endpoint.orders_plan_pending(symbol: session.symbol)
    # TODO(後続 phase): response["data"] から Exchange::AlgoOrder upsert
    #   + 各 plan_id について order_endpoint.plan_sub_order(plan_id:) を呼んで sub-order を反映
    response
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] reconcile_orders_plan_pending failed: #{e.class.name}: #{e.message}"
    )
    nil
  end

  # 直近 24h の履歴 plan order を取得する(MVP デフォルト範囲 / 設計書明示なしのため固定値).
  RECONCILE_PLAN_HISTORY_LOOKBACK_MS = 24 * 60 * 60 * 1000
  private_constant :RECONCILE_PLAN_HISTORY_LOOKBACK_MS

  def reconcile_orders_plan_history(session)
    end_time = (Time.current.to_f * 1000).to_i
    start_time = end_time - RECONCILE_PLAN_HISTORY_LOOKBACK_MS

    response = order_endpoint.orders_plan_history(
      symbol: session.symbol, start_time: start_time, end_time: end_time
    )
    # TODO(後続 phase): response["data"] から AlgoOrder 履歴 upsert
    response
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] reconcile_orders_plan_history failed: #{e.class.name}: #{e.message}"
    )
    nil
  end

  def reconcile_position_all(session)
    response = position_endpoint.position_all(margin_coin: session.margin_coin, symbol: session.symbol)
    # TODO(後続 phase): response["data"] から Exchange::PositionSnapshot upsert
    response
  rescue StandardError => e
    logger.warn(
      "[LiveTradingWorker] reconcile_position_all failed: #{e.class.name}: #{e.message}"
    )
    nil
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

  def ai_filter_service
    @ai_filter_service ||= Domain::AiFilterService.new(
      invoker: Infrastructure::ClaudeCodeInvoker.new(logger: logger),
      validator: Domain::AiResponseValidatorService.new,
      template_repository: Infrastructure::ClaudeCodePromptTemplates,
      log_recorder: Integration::AiInvocationLog
    )
  end

  def risk_guard_service
    @risk_guard_service ||= Domain::RiskGuardService.new
  end

  def order_endpoint
    @order_endpoint ||= Infrastructure::BitgetOrderEndpoint.new(rest_client: build_rest_client)
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
