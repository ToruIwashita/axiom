module ApplicationServices
  # ライブトレードセッションのライフサイクル(start / stop / emergency_stop)を提供する
  # アプリケーション層サービス(設計書 02_§5.2.4 / 05_§1.5.1).
  #
  # トランザクション境界は各メソッド = 1 トランザクション(AR 暗黙 transaction).
  # `LiveTradingWorker.perform_async` は `enqueue_after_transaction_commit = :always` 既設定
  # により Session 作成 commit 後に enqueue 保証される.
  class LiveTradingSessionService
    # ライブトレードセッションを開始する.
    #
    # フロー:
    # 1. Strategy::Revision と Strategy::Definition の整合検証
    # 2. 受入条件チェック(`acceptable_for_live?` && `uses_live_forbidden_input == false`)
    # 3. `LiveTrading::Session.create!(status: :starting, ...)`
    # 4. `LiveTradingWorker.perform_async(session.id)`
    #
    # @param strategy_definition_id [Integer]
    # @param strategy_revision_id [Integer]
    # @param risk_policy_id [Integer]
    # @param symbol [String]
    # @param leverage [Integer]
    # @param margin_mode [String] "isolated" / "crossed"
    # @param position_mode [String] "one_way_mode" / "hedge_mode"
    # @param asset_mode [String] "single" / "union"
    # @param margin_coin [String]
    # @param emergency_stop_mode [String] "cancel_only" / "cancel_and_market_close" / "cancel_and_reduce_only"
    # @return [LiveTrading::Session] status: :starting で作成された Session
    # @raise [ActiveRecord::RecordNotFound] 各 ID が存在しない場合
    # @raise [ArgumentError] 整合検証失敗 / 受入条件不合格の場合
    def start_session(strategy_definition_id:, strategy_revision_id:, risk_policy_id:,
                      symbol:, leverage:, margin_mode:, position_mode:, asset_mode:,
                      margin_coin:, emergency_stop_mode:)
      revision = Strategy::Revision.assert_strategy_definition_consistency!(
        strategy_revision_id, strategy_definition_id
      )

      unless revision.acceptable_for_live?
        raise ArgumentError,
              "revision_id=#{strategy_revision_id} is not acceptable for live (status=#{revision.status})"
      end

      if revision.uses_live_forbidden_input
        raise ArgumentError,
              "revision_id=#{strategy_revision_id} uses_live_forbidden_input is true"
      end

      session = LiveTrading::Session.create!(
        strategy_definition_id: strategy_definition_id,
        strategy_revision_id: strategy_revision_id,
        risk_policy_id: risk_policy_id,
        symbol: symbol,
        leverage: leverage,
        margin_mode: margin_mode,
        position_mode: position_mode,
        asset_mode: asset_mode,
        margin_coin: margin_coin,
        emergency_stop_mode: emergency_stop_mode,
        status: "starting"
      )

      LiveTradingWorker.perform_async(session.id)

      session
    end

    # 指定 Session を停止する(kill-switch シグナル送信).
    # `emergency_stop_mode` を `mode` で上書き後 `start_stopping!` を呼ぶ.
    # Phase 3.4b R-12 反映: mode を EMERGENCY_STOP_MODES allow-list で Fail Fast 検証する.
    #
    # @param session_id [Integer]
    # @param mode [String] 停止モード(emergency_stop_mode の上書き値)
    # @return [LiveTrading::Session] status: :stopping に遷移済の Session
    # @raise [ActiveRecord::RecordNotFound]
    # @raise [ArgumentError] mode が EMERGENCY_STOP_MODES に含まれない場合(nil / 不正値含む)
    # @raise [LiveTrading::Session::InvalidTransitionError] running / cooling_down 以外から呼ばれた場合
    def stop(session_id:, mode:)
      assert_valid_emergency_stop_mode!(mode)
      session = LiveTrading::Session.find(session_id)
      session.update!(emergency_stop_mode: mode)
      session.start_stopping!
      session
    end

    # 全 running セッションを一斉停止する.
    #
    # @param mode [String] 停止モード(emergency_stop_mode の一括上書き値)
    # @return [Array<LiveTrading::Session>] 停止対象になった Session 群(running 0 件なら空配列)
    # @raise [ArgumentError] mode が EMERGENCY_STOP_MODES に含まれない場合(nil / 不正値含む)
    def emergency_stop(mode:)
      assert_valid_emergency_stop_mode!(mode)
      LiveTrading::Session.where(status: "running").map do |session|
        stop(session_id: session.id, mode: mode)
      end
    end

    private

    def assert_valid_emergency_stop_mode!(mode)
      return if LiveTrading::Session::EMERGENCY_STOP_MODES.include?(mode)

      raise ArgumentError,
            "mode must be one of #{LiveTrading::Session::EMERGENCY_STOP_MODES.inspect} but got #{mode.inspect}"
    end
  end
end
